const std = @import("std");
const mecha = @import("mecha/mecha.zig");
const reflect = @import("reflect.zig");

const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const net = std.net;
const os = std.os;

usingnamespace @import("auto/xproto.zig");

pub const bigreq = @import("auto/bigreq.zig");
pub const composite = @import("auto/composite.zig");
pub const damage = @import("auto/damage.zig");
pub const dpms = @import("auto/dpms.zig");
pub const dri2 = @import("auto/dri2.zig");
pub const dri3 = @import("auto/dri3.zig");
pub const ge = @import("auto/ge.zig");
pub const glx = @import("auto/glx.zig");
pub const present = @import("auto/present.zig");
pub const randr = @import("auto/randr.zig");
pub const record = @import("auto/record.zig");
pub const render = @import("auto/render.zig");
pub const res = @import("auto/res.zig");
pub const screensaver = @import("auto/screensaver.zig");
pub const shape = @import("auto/shape.zig");
pub const shm = @import("auto/shm.zig");
pub const sync = @import("auto/sync.zig");
pub const xc_misc = @import("auto/xc_misc.zig");
pub const xevie = @import("auto/xevie.zig");
pub const xf86dri = @import("auto/xf86dri.zig");
pub const xf86vidmode = @import("auto/xf86vidmode.zig");
pub const xfixes = @import("auto/xfixes.zig");
pub const xinerama = @import("auto/xinerama.zig");
pub const input = @import("auto/xinput.zig");
pub const xkb = @import("auto/xkb.zig");
pub const xprint = @import("auto/xprint.zig");
pub const selinux = @import("auto/xselinux.zig");
pub const xtest = @import("auto/xtest.zig");
pub const xv = @import("auto/xv.zig");
pub const xvmc = @import("auto/xvmc.zig");

pub const Extension = struct {
    name: []const u8,
    global_id: u32,
};

const Connection = struct {};

pub fn connect() !Connection {
    const display_str = os.getenv("DISPLAY") orelse return error.DisplayNotFound;
    const display = try Display.parse(display_str);

    const handle = try display.connect();
    errdefer handle.close();

    var hostname_buf: [os.HOST_NAME_MAX]u8 = undefined;
    const hostname = try os.gethostname(&hostname_buf);

    const xautority = try openXAuthority();
    defer xautority.close();

    var auth_buf: [Auth.max_size]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&auth_buf);

    const auth = while (Auth.read(xautority.reader(), &fba.allocator) catch |err| switch (err) {
        error.EndOfStream => null,
        else => |e| return e,
    }) |auth| {
        if (mem.eql(u8, auth.address, hostname))
            break auth;
    } else return error.AuthNotFound;

    return setup(handle, auth);
}

fn setup(handle: fs.File, auth: Auth) !Connection {
    try reflect.encode(handle.writer(), SetupRequest, .{
        .byte_order = if (@import("std").builtin.endian == .Big) 0x42 else 0x6c,
        .pad0 = 0,
        .protocol_major_version = 11,
        .protocol_minor_version = 0,
        .pad1 = [2]u8{ 0, 0 },
        .authorization_protocol_name = auth.name,
        .authorization_protocol_data = auth.data,
    });
    const SetupAuthenticate2 = extern struct {
        @"status": u8,
        @"pad0": [5]u8,
        @"length": u16,
    };

    var buf: [math.maxInt(u16) * 4]u8 = undefined;
    const header = try handle.reader().readStruct(SetupAuthenticate);
    // std.debug.warn("{}\n", .{header});

    // const setup_buf = buf[0 .. header.length * 4];
    // try handle.reader().readNoEof(setup_buf);

    switch (header.status) {
        0 => return error.SetupFailed,
        2 => unreachable, // TODO: authenticate
        1 => {},
        else => return error.InvalidStatus,
    }

    // const setup = mem.bytesAsValue(Setup, setup_buf[0..@sizeOf(Setup)]);
    // const vendor = setup_buf[@sizeOf(Setup)..][0..setup.vendor_len];

    // const formats_start = @sizeOf(Setup) + setup.vendor_len;
    // const formats_end = formats_start + setup.pixmap_formats_len * @sizeOf(FORMAT);
    // const formats = mem.bytesAsSlice(FORMAT, setup_buf[formats_start..formats_end]);

    return @as(Connection, undefined);
}

pub const Display = struct {
    host: []const u8,
    protocol: []const u8,
    display: u16,
    screen: u16,

    pub fn parse(str: []const u8) !Display {
        const result = parseDisplay(str) orelse return error.InvalidDisplay;
        return Display{
            .protocol = result.value[0] orelse "",
            .host = result.value[1],
            .display = result.value[2],
            .screen = result.value[3] orelse 0,
        };
    }

    pub fn connect(display: Display) !fs.File {
        if (display.host.len != 0) {
            const port = 6000 + display.display;
            const address = try net.Address.parseIp(display.host, port);
            return net.tcpConnectToAddress(address);
        } else {
            var buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            const path = fmt.bufPrint(&buf, "/tmp/.X11-unix/X{}", .{display.display}) catch unreachable;
            return try net.connectUnixSocket(path);
        }
    }

    usingnamespace mecha;

    const parseDisplay = combine(.{
        opt(protocol),
        host,
        displayId,
        opt(combine(.{ ascii.char('.'), screenId })),
        eos,
    });

    const protocol = combine(.{
        many(ascii.not(ascii.char('/'))),
        ascii.char('/'),
    });

    const host = combine(.{
        many(ascii.not(ascii.char(':'))),
        ascii.char(':'),
    });

    const displayId = int(u16, 10);
    const screenId = int(u16, 10);
};

pub const Auth = struct {
    family: u16,
    address: []u8,
    number: []u8,
    name: []u8,
    data: []u8,

    /// Maximum size an Auth can ever occupy when encoded. This is
    /// useful for when you wonna avoid the heap by allocating all
    /// the data with a heap.FixedBufferAllocator.
    pub const max_size = math.maxInt(u16) * 4 + @sizeOf(u16);

    pub fn read(stream: anytype, allocator: *mem.Allocator) !Auth {
        const Read = struct {
            fn string(s: anytype, a: *mem.Allocator) ![]u8 {
                const len = try s.readIntBig(u16);
                const result = try a.alloc(u8, len);
                errdefer a.free(result);

                try s.readNoEof(result);
                return result;
            }
        };

        const family = try stream.readIntBig(u16);
        const address = try Read.string(stream, allocator);
        errdefer allocator.free(address);
        const number = try Read.string(stream, allocator);
        errdefer allocator.free(number);
        const name = try Read.string(stream, allocator);
        errdefer allocator.free(name);
        const data = try Read.string(stream, allocator);
        errdefer allocator.free(data);

        return Auth{
            .family = family,
            .address = address,
            .number = number,
            .name = name,
            .data = data,
        };
    }

    pub fn deinit(auth: Auth, allocator: *Allocator) void {
        allocator.free(auth.address);
        allocator.free(auth.number);
        allocator.free(auth.name);
        allocator.free(auth.data);
    }
};

pub fn openXAuthority() !fs.File {
    if (os.getenv("XAUTHORITY")) |path|
        return fs.openFileAbsolute(path, .{});

    const home = os.getenv("HOME") orelse return error.HomeDirectoryNotFound;
    var home_dir = try fs.cwd().openDir(home, .{});
    defer home_dir.close();

    return home_dir.openFile(".Xauthority", .{});
}

test "" {
    @import("std").testing.refAllDecls(@This());
}

test "connect" {
    // const connection = try connect();
}
