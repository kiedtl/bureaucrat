const std = @import("std");
const mem = std.mem;
const math = std.math;
const fmt = std.fmt;
const meta = std.meta;
const assert = std.debug.assert;

const ASTNode = @import("common.zig").ASTNode;
const ASTNodeList = @import("common.zig").ASTNodeList;
const Ins = @import("common.zig").Ins;
const Op = @import("common.zig").Op;
const StackBuffer = @import("buffer.zig").StackBuffer;

const WK_STACK = @import("common.zig").WK_STACK;
const RT_STACK = @import("common.zig").RT_STACK;
const STACK_SZ = @import("common.zig").STACK_SZ;

const gpa = &@import("common.zig").gpa;

const VMError = error{
    StackUnderflow,
    StackOverflow,
    InvalidType,
};

pub const VM = struct {
    stacks: [2]StackType,
    program: []const Ins,
    pc: u8,
    stopped: bool = false,

    pub const StackType = StackBuffer(u8, STACK_SZ);

    pub fn init(program: []const Ins) VM {
        return .{
            .stacks = [1]StackType{StackType.init(null)} ** 2,
            .program = program,
            .pc = 0,
        };
    }

    pub fn execute(self: *VM) VMError!void {
        assert(!self.stopped);
        while (!self.stopped and self.pc < self.program.len) {
            const ins = self.program[self.pc];
            if (try self.executeIns(ins))
                self.pc += 1;
        }
    }

    pub fn executeIns(self: *VM, ins: Ins) VMError!bool {
        //std.log.info("pc: {}\tins: {}", .{ self.pc, ins });
        switch (ins.op) {
            .Olit => |v| try self.push(ins.stack, v),
            .Osr => |f| {
                try self.push(ins.stack, self.pc + 1);
                self.pc = f orelse try self.pop(ins.stack);
                return false;
            },
            .Oj => |j| {
                self.pc = j orelse try self.pop(ins.stack);
                return false;
            },
            .Ozj => |j| {
                const addr = j orelse try self.pop(ins.stack);
                if ((try self.pop(ins.stack)) != 0) {
                    self.pc = addr;
                    return false;
                }
            },
            .Ohalt => self.stopped = true,
            .Onac => |f| try (findBuiltin(f).?.func)(self, ins.stack),
            .Opick => |i| {
                const ind = i orelse try self.pop(ins.stack);
                const len = self.stacks[ins.stack].len;
                if (ind >= len) {
                    return error.StackUnderflow;
                }
                try self.push(ins.stack, self.stacks[ins.stack].data[len - ind - 1]);
            },
            .Oroll => |i| {
                const ind = i orelse try self.pop(ins.stack);
                const len = self.stacks[ins.stack].len;
                if (ind >= len) {
                    return error.StackUnderflow;
                }
                const item = self.stacks[ins.stack].orderedRemove(len - ind - 1) catch unreachable;
                try self.push(ins.stack, item);
            },
            .Odrop => |i| {
                const count = i orelse try self.pop(ins.stack);
                const len = self.stacks[ins.stack].len;
                self.stacks[ins.stack].resizeTo(len - count);
            },
            .Oeq => {
                const b = try self.pop(ins.stack);
                const a = try self.pop(ins.stack);
                try self.push(ins.stack, if (a == b) @as(u8, 1) else 0);
            },
            .Oneq => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, if (a != b) @as(u8, 1) else 0);
            },
            .Olt => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, if (a < b) @as(u8, 1) else 0);
            },
            .Ogt => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, if (a > b) @as(u8, 1) else 0);
            },
            .Odmod => {
                const dvs = try self.pop(ins.stack);
                const dvd = try self.pop(ins.stack);
                try self.push(ins.stack, dvd % dvs);
                try self.push(ins.stack, dvd / dvs);
            },
            .Omul => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, a * b);
            },
            .Oadd => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, a + b);
            },
            .Osub => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, b - a);
            },
            .Oeor => {
                const a = try self.pop(ins.stack);
                const b = try self.pop(ins.stack);
                try self.push(ins.stack, a ^ b);
            },
            .Ostash => {
                const src = ins.stack;
                const dst = (ins.stack + 1) % 2;
                const v = try self.pop(src);
                try self.push(dst, v);
            },
        }
        return true;
    }

    pub fn pop(self: *VM, stk: usize) VMError!u8 {
        if (self.stacks[stk].len == 0) {
            return error.StackUnderflow;
        }
        return self.stacks[stk].pop() catch unreachable;
    }

    pub fn push(self: *VM, stk: usize, value: u8) VMError!void {
        // XXX: not bothering matching on error since it can only return .NoSpaceLeft
        self.stacks[stk].append(value) catch return error.StackOverflow;
    }
};

// Builtins
//
// (This is temporary)
//
// {{{

pub const Builtin = struct {
    name: []const u8,
    func: fn (vm: *VM, stack: usize) VMError!void,
};

pub const BUILTINS = [_]Builtin{
    Builtin{
        .name = "print-stack",
        .func = struct {
            pub fn f(vm: *VM, stk: usize) VMError!void {
                for (vm.stacks[stk].constSlice()) |item, i| {
                    std.log.info("{}\t{}", .{ i, item });
                }
            }
        }.f,
    },
};

pub fn findBuiltin(name: []const u8) ?Builtin {
    return for (&BUILTINS) |builtin| {
        if (mem.eql(u8, builtin.name, name))
            break builtin;
    } else null;
}

// }}}
