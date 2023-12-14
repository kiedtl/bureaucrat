const std = @import("std");
const mem = std.mem;
const math = std.math;
const fmt = std.fmt;
const meta = std.meta;
const assert = std.debug.assert;

const emitter = @import("emitter.zig");
const ASTNode = @import("common.zig").ASTNode;
const ASTNodeList = @import("common.zig").ASTNodeList;
const Ins = @import("common.zig").Ins;
const Program = @import("common.zig").Program;
const StackBuffer = @import("buffer.zig").StackBuffer;

const WK_STACK = @import("common.zig").WK_STACK;
const RT_STACK = @import("common.zig").RT_STACK;
const STACK_SZ = @import("common.zig").STACK_SZ;

const gpa = &@import("common.zig").gpa;

const c = @cImport({
    @cInclude("uxn.h");
    @cInclude("devices/system.h");
    @cInclude("devices/console.h");
    @cInclude("devices/screen.h");
    @cInclude("devices/audio.h");
    @cInclude("devices/file.h");
    @cInclude("devices/controller.h");
    @cInclude("devices/mouse.h");
    @cInclude("devices/datetime.h");
});

extern "c" fn set_zoom(z: u8, win: c_int) void;
extern "c" fn emu_init() c_int;
extern "c" fn emu_restart(u: [*c]c.Uxn, rom: [*c]u8, soft: c_int) void;
extern "c" fn emu_redraw(u: [*c]c.Uxn) c_int;
extern "c" fn emu_resize(width: c_int, height: c_int) c_int;
extern "c" fn emu_end(uxn: [*c]c.Uxn) c_int;
extern "c" fn base_emu_deo(uxn: [*c]c.Uxn, addr: c_char) void;

pub const VM = struct {
    uxn: c.Uxn = undefined,
    ram: []u8,
    here: usize = 0,

    is_testing: bool = false,
    is_breakpoint: bool = false,

    pub fn init(assembled: []const Ins) VM {
        const ram = gpa.allocator().alloc(u8, 0x10000 * c.RAM_PAGES) catch
            @panic("please uninstall Chrome before proceeding (OOM)");
        @memset(ram, 0);

        var fbstream = std.io.fixedBufferStream(ram);
        var writer = fbstream.writer();
        writer.writeByteNTimes(0, 0x0100) catch unreachable;
        emitter.spitout(writer, assembled) catch unreachable;

        var self = mem.zeroes(VM);
        self.ram = ram;
        self.uxn.ram = ram.ptr;
        self.here = c.PAGE_PROGRAM + assembled.len;

        c.system_connect(0x0, c.SYSTEM_VERSION, c.SYSTEM_DEIMASK, c.SYSTEM_DEOMASK);
        c.system_connect(0x1, c.CONSOLE_VERSION, c.CONSOLE_DEIMASK, c.CONSOLE_DEOMASK);
        c.system_connect(0x2, c.SCREEN_VERSION, c.SCREEN_DEIMASK, c.SCREEN_DEOMASK);
        c.system_connect(0x3, c.AUDIO_VERSION, c.AUDIO_DEIMASK, c.AUDIO_DEOMASK);
        c.system_connect(0x4, c.AUDIO_VERSION, c.AUDIO_DEIMASK, c.AUDIO_DEOMASK);
        c.system_connect(0x5, c.AUDIO_VERSION, c.AUDIO_DEIMASK, c.AUDIO_DEOMASK);
        c.system_connect(0x6, c.AUDIO_VERSION, c.AUDIO_DEIMASK, c.AUDIO_DEOMASK);
        c.system_connect(0x8, c.CONTROL_VERSION, c.CONTROL_DEIMASK, c.CONTROL_DEOMASK);
        c.system_connect(0x9, c.MOUSE_VERSION, c.MOUSE_DEIMASK, c.MOUSE_DEOMASK);
        c.system_connect(0xa, c.FILE_VERSION, c.FILE_DEIMASK, c.FILE_DEOMASK);
        c.system_connect(0xb, c.FILE_VERSION, c.FILE_DEIMASK, c.FILE_DEOMASK);
        c.system_connect(0xc, c.DATETIME_VERSION, c.DATETIME_DEIMASK, c.DATETIME_DEOMASK);

        set_zoom(2, 0);
        if (emu_init() == 0)
            @panic("Emulator failed to init.");

        return self;
    }

    pub fn execute(self: *VM) void {
        self.is_testing = false;

        // TODO: argument handling for roms that need it
        //self.uxn.dev[0x17] = argc - i;

        var pc: c_ushort = c.PAGE_PROGRAM;
        while (true) {
            pc = c.uxn_eval_once(&self.uxn, pc);
            if (pc <= 1) break;
            assert(!self.is_breakpoint);
        }

        _ = emu_end(&self.uxn);
    }

    fn _failTest(stderr: anytype, comptime format: []const u8, args: anytype) !void {
        const failstr = "\x1b[2D\x1b[31m!!\x1b[m\n";
        stderr.print("{s}", .{failstr}) catch unreachable;
        stderr.print("\x1b[32m> \x1b[m" ++ format ++ "\n\n", args) catch unreachable;
        return error.Fail;
    }

    fn _handleBreak(self: *VM, pc: c_ushort, stderr: anytype, program: *Program) !void {
        // TODO: underflow checks
        const wst: [*c]u8 = @ptrCast(&self.uxn.wst.dat[self.uxn.wst.ptr - 1]);
        const tosb = wst.*;
        const toss = @as(u16, @intCast((wst - @as(u8, 1)).*)) << 8 | wst.*;
        const breakpoint = for (program.breakpoints.items) |brk| {
            if (brk.romloc + 0x100 == pc) break brk;
        } else return; // TODO: warn about unknown breakpoints
        switch (breakpoint.type) {
            .TosShouldEq => |v| {
                if (v.typ.bits(program).? == 16) {
                    if (v.toU16(program) != toss) {
                        try _failTest(stderr, "Expected 0x{x:0>4}, got 0x{x:0>4}", .{
                            v.toU16(program), toss,
                        });
                    }
                    self.uxn.wst.ptr -= 2;
                } else if (v.typ.bits(program).? == 8) {
                    if (v.toU8(program) != tosb) {
                        try _failTest(stderr, "Expected 0x{x:0>2}, got 0x{x:0>2}", .{
                            v.toU8(program), tosb,
                        });
                    }
                    self.uxn.wst.ptr -= 1;
                } else unreachable;
            },
        }
    }

    pub fn executeTests(self: *VM, program: *Program) void {
        const stderr = std.io.getStdErr().writer();

        self.is_testing = true;

        test_loop: for (program.defs.items) |decl_node| {
            const decl = decl_node.node.Decl;
            if (!decl.is_test) continue;
            assert(decl.is_analysed);

            stderr.print("{s}", .{decl.name}) catch unreachable;
            stderr.writeByteNTimes(' ', 50 - decl.name.len) catch unreachable;
            stderr.print("\x1b[34..\x1b[m", .{}) catch unreachable;

            // TODO: assert that stacks are empty after each test
            self.uxn.wst.ptr = 0;
            self.uxn.rst.ptr = 0;

            @memset(self.ram[self.here..], 0);

            var pc: c_ushort = @as(c_ushort, @intCast(decl_node.romloc)) + 0x100;
            assert(pc != 0xFFFF);

            while (true) {
                pc = c.uxn_eval_once(&self.uxn, pc);
                if (pc == 0) @panic("test halted");
                if (pc == 1) break;

                if (self.is_breakpoint) {
                    self.is_breakpoint = false;
                    _handleBreak(self, pc, stderr, program) catch continue :test_loop;
                }
            }

            stderr.print("\x1b[2D\x1b[36mOK\x1b[m\n", .{}) catch unreachable;
        }

        _ = emu_end(&self.uxn);
    }
};

pub export fn emu_deo(u: [*c]c.Uxn, addr: c_char) callconv(.C) void {
    const self = @fieldParentPtr(VM, "uxn", u);
    if (self.is_testing and addr == 0x0e) {
        self.is_breakpoint = true;
    } else {
        base_emu_deo(u, addr);
    }
}
