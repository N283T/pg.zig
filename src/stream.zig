const std = @import("std");
const lib = @import("lib.zig");

const openssl = lib.openssl;

const posix = std.posix;

const Conn = lib.Conn;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const DEFAULT_HOST = "127.0.0.1";

pub const Stream = if (lib.has_openssl) TLSStream else PlainStream;

const TLSStream = struct {
    valid: bool,
    ssl: ?*openssl.SSL,
    socket: posix.socket_t,
    io: Io,
    net_stream: Io.net.Stream,

    pub fn connect(allocator: Allocator, opts: Conn.Opts, ctx_: ?*openssl.SSL_CTX) !Stream {
        const plain = try PlainStream.connect(allocator, opts, null);
        errdefer plain.close();

        const socket = plain.socket;
        const io = plain.io;
        const net_stream = plain.net_stream;

        var ssl: ?*openssl.SSL = null;
        if (ctx_) |ctx| {
            // PostgreSQL TLS starts off as a plain connection which we upgrade
            try writeStream(io, net_stream, &.{ 0, 0, 0, 8, 4, 210, 22, 47 });
            var buf = [1]u8{0};
            _ = try readStream(io, net_stream, &buf);
            if (buf[0] != 'S') {
                return error.SSLNotSupportedByServer;
            }

            ssl = openssl.SSL_new(ctx) orelse return error.SSLNewFailed;
            errdefer openssl.SSL_free(ssl);

            if (opts.host) |host| {
                if (isHostName(host)) {
                    // don't send this for an ip address
                    var owned = false;
                    const h = opts._hostz orelse blk: {
                        owned = true;
                        break :blk try allocator.dupeZ(u8, host);
                    };

                    defer if (owned) {
                        allocator.free(h);
                    };

                    if (openssl.SSL_set_tlsext_host_name(ssl, h.ptr) != 1) {
                        return error.SSLHostNameFailed;
                    }
                }
                switch (opts.tls) {
                    .verify_full => openssl.SSL_set_verify(ssl, openssl.SSL_VERIFY_PEER, null),
                    else => {},
                }
            }

            if (openssl.SSL_set_fd(ssl, if (@import("builtin").os.tag == .windows) @intCast(@intFromPtr(socket)) else socket) != 1) {
                return error.SSLSetFdFailed;
            }

            {
                const ret = openssl.SSL_connect(ssl);
                if (ret != 1) {
                    const verification_code = openssl.SSL_get_verify_result(ssl);
                    if (comptime lib._stderr_tls) {
                        lib.printSSLError();
                    }
                    if (verification_code != openssl.X509_V_OK) {
                        if (comptime lib._stderr_tls) {
                            std.debug.print("ssl verification error: {s}\n", .{openssl.X509_verify_cert_error_string(verification_code)});
                        }
                        return error.SSLCertificationVerificationError;
                    }
                    return error.SSLConnectFailed;
                }
            }
        }

        return .{
            .ssl = ssl,
            .valid = true,
            .socket = socket,
            .io = io,
            .net_stream = net_stream,
        };
    }

    pub fn close(self: *Stream) void {
        if (self.ssl) |ssl| {
            if (self.valid) {
                _ = openssl.SSL_shutdown(ssl);
                self.valid = false;
            }
            openssl.SSL_free(ssl);
        }
        self.net_stream.close(self.io);
    }

    pub fn shutdown(self: *Stream) void {
        self.net_stream.shutdown(self.io, .both) catch {};
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        if (self.ssl) |ssl| {
            const result = openssl.SSL_write(ssl, data.ptr, @intCast(data.len));
            if (result <= 0) {
                self.valid = false;
                return error.SSLWriteFailed;
            }
            return;
        }
        return writeStream(self.io, self.net_stream, data);
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        if (self.ssl) |ssl| {
            var read_len: usize = undefined;
            const result = openssl.SSL_read_ex(ssl, buf.ptr, @intCast(buf.len), &read_len);
            if (result <= 0) {
                self.valid = false;
                return error.SSLReadFailed;
            }
            return read_len;
        }

        return readStream(self.io, self.net_stream, buf);
    }
};

const PlainStream = struct {
    socket: posix.socket_t,
    io: Io,
    net_stream: Io.net.Stream,

    pub fn connect(allocator: Allocator, opts: Conn.Opts, _: anytype) !PlainStream {
        _ = allocator;
        const io = opts.io;
        const net_stream = blk: {
            const host = opts.host orelse DEFAULT_HOST;
            if (host.len > 0 and host[0] == '/') {
                if (comptime Io.net.has_unix_sockets == false or std.posix.AF == void) {
                    return error.UnixPathNotSupported;
                }
                const addr = try Io.net.UnixAddress.init(host);
                break :blk try addr.connect(io);
            }
            const port = opts.port orelse 5432;
            if (Io.net.IpAddress.parse(host, port)) |addr| {
                break :blk try addr.connect(io, .{ .mode = .stream });
            } else |_| {
                const hostname = try Io.net.HostName.init(host);
                break :blk try hostname.connect(io, port, .{ .mode = .stream });
            }
        };
        errdefer net_stream.close(io);

        return .{
            .socket = net_stream.socket.handle,
            .io = io,
            .net_stream = net_stream,
        };
    }

    pub fn close(self: *const PlainStream) void {
        self.net_stream.close(self.io);
    }

    pub fn shutdown(self: *const PlainStream) void {
        self.net_stream.shutdown(self.io, .both) catch {};
    }

    pub fn writeAll(self: *const PlainStream, data: []const u8) !void {
        return writeStream(self.io, self.net_stream, data);
    }

    pub fn read(self: *const PlainStream, buf: []u8) !usize {
        return readStream(self.io, self.net_stream, buf);
    }
};

fn readStream(io: Io, stream: Io.net.Stream, buf: []u8) !usize {
    _ = io;
    if (buf.len == 0) return 0;
    while (true) {
        const rc = std.c.read(stream.socket.handle, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return 0,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        }
    }
}

fn writeStream(io: Io, stream: Io.net.Stream, data: []const u8) !void {
    _ = io;
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = std.c.write(stream.socket.handle, data[pos..].ptr, data.len - pos);
        switch (std.posix.errno(rc)) {
            .SUCCESS => pos += @intCast(rc),
            .INTR => continue,
            .BADF => return error.SocketUnconnected,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            .PIPE => return error.SocketUnconnected,
            else => return error.WriteFailed,
        }
    }
}

fn isHostName(host: []const u8) bool {
    if (std.mem.findScalar(u8, host, ':') != null) {
        // IPv6
        return false;
    }
    return std.mem.findNone(u8, host, "0123456789.") != null;
}
