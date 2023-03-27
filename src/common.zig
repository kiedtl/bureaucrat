const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const fmt = std.fmt;

const LinkedList = @import("list.zig").LinkedList;

// ----------------------------------------------------------------------------

pub const WK_STACK = 0;
pub const RT_STACK = 1;
pub const STACK_SZ = 255;

pub var gpa = std.heap.GeneralPurposeAllocator(.{
    // Probably should enable this later on to track memory usage, if
    // allocations become too much
    .enable_memory_limit = false,

    .safety = true,

    // Probably would enable this later?
    .thread_safe = false,

    .never_unmap = false,
}){};

//pub const ASTNodeList = LinkedList(ASTNode);
pub const ASTNodeList = std.ArrayList(ASTNode);
pub const ASTNodePtrList = std.ArrayList(*ASTNode);

pub const Value = union(enum) {
    U8: u8,
    EnumLit: []const u8,

    pub const Tag = std.meta.Tag(Value);

    pub fn from(astval: ASTNode.ASTValue) Value {
        return switch (astval) {
            .T => .{ .U8 = 1 },
            .Nil => .{ .U8 = 0 },
            .U8 => |v| .{ .U8 = v },
            .Codepoint => |v| .{ .U8 = v },
            .EnumLit => |e| .{ .EnumLit = e },
        };
    }

    pub fn asBool(self: Value) bool {
        return switch (self) {
            .U8 => |n| n != 0,
            .EnumLit => true,
        };
    }
};

pub const ASTNode = struct {
    __prev: ?*ASTNode = null,
    __next: ?*ASTNode = null,

    node: Type,
    srcloc: usize,
    romloc: usize = 0,

    pub const Tag = std.meta.Tag(ASTNode.Type);

    pub const Type = union(enum) {
        None, // Placeholder for removed ast values
        Decl: Decl, // word declaraction
        Mac: Mac, // macro declaraction
        Call: []const u8,
        Loop: Loop,
        Cond: Cond,
        Asm: Ins,
        Value: ASTValue,
        Quote: Quote,
    };

    pub const ASTValue = union(enum) {
        T,
        Nil,
        U8: u8,
        Codepoint: u8,
        EnumLit: []const u8,

        pub const Tag = std.meta.Tag(ASTValue);
    };

    pub const Cond = struct {
        branches: Branch.List,
        else_branch: ?ASTNodeList,

        pub const Branch = struct {
            cond: ASTNodeList,
            body: ASTNodeList,

            pub const List = std.ArrayList(Branch);
        };
    };

    pub const Loop = struct {
        loop: Loop.Type,
        body: ASTNodeList,

        pub const Type = union(enum) {
            Until: struct { cond: ASTNodeList },
        };
    };

    pub const Decl = struct {
        name: []const u8,
        body: ASTNodeList,
    };

    pub const Mac = struct {
        name: []const u8,
        body: ASTNodeList,
    };

    pub const Quote = struct {
        body: ASTNodeList,
    };
};

pub const Program = struct {
    ast: ASTNodeList,
    defs: ASTNodePtrList,
    macs: ASTNodePtrList,
};

pub const Op = union(enum) {
    Olit: Value,
    Osr: ?usize,
    Oj: ?usize,
    Ozj: ?usize,
    Ohalt,
    Onac: []const u8,
    Opick: ?usize,
    Oroll: ?usize,
    Odrop: ?usize,
    Oeq,
    Oneq,
    Olt,
    Ogt,
    Oeor,
    Odmod,
    Omul,
    Oadd,
    Osub,
    Ostash,

    pub const Tag = meta.Tag(Op);

    pub fn fromTag(tag: Tag) !Op {
        return switch (tag) {
            .Onac, .Olit => error.NeedsArg,
            .Osr => .{ .Osr = null },
            .Oj => .{ .Oj = null },
            .Ozj => .{ .Ozj = null },
            .Ohalt => .Ohalt,
            .Opick => .{ .Opick = null },
            .Oroll => .{ .Oroll = null },
            .Odrop => .{ .Odrop = null },
            .Oeq => .Oeq,
            .Oneq => .Oneq,
            .Olt => .Olt,
            .Ogt => .Ogt,
            .Oeor => .Oeor,
            .Odmod => .Odmod,
            .Omul => .Omul,
            .Oadd => .Oadd,
            .Osub => .Osub,
            .Ostash => .Ostash,
        };
    }

    pub fn format(
        value: @This(),
        comptime f: []const u8,
        options: fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;

        if (comptime mem.eql(u8, f, "")) {
            //
        } else {
            @compileError("Unknown format string: '" ++ f ++ "'");
        }

        switch (value) {
            .Olit => |l| try fmt.format(writer, "{}", .{l}),
            .Oj => |j| try fmt.format(writer, "{}", .{j}),
            .Ozj => |j| try fmt.format(writer, "{}", .{j}),
            .Osr => |j| try fmt.format(writer, "{}", .{j}),
            .Onac => |n| try fmt.format(writer, "'{s}'", .{n}),
            .Opick => |i| try fmt.format(writer, "{}", .{i}),
            .Oroll => |i| try fmt.format(writer, "{}", .{i}),
            .Omul => |a| try fmt.format(writer, "{}", .{a}),
            .Oadd => |a| try fmt.format(writer, "{}", .{a}),
            .Osub => |a| try fmt.format(writer, "{}", .{a}),
            else => try fmt.format(writer, "@", .{}),
        }
    }
};

pub const Ins = struct {
    stack: usize,
    op: Op,

    pub const List = std.ArrayList(Ins);

    pub fn format(
        value: @This(),
        comptime f: []const u8,
        options: fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;

        if (comptime mem.eql(u8, f, "")) {
            //
        } else {
            @compileError("Unknown format string: '" ++ f ++ "'");
        }

        var str: []const u8 = undefined;
        inline for (@typeInfo(Op.Tag).Enum.fields) |enum_field| {
            if (@intToEnum(Op.Tag, enum_field.value) == value.op) {
                str = enum_field.name;
                //break; // FIXME: Wait for that bug to be fixed, then uncomment
            }
        }

        try fmt.format(writer, "<[{}] {s} {}>", .{ value.stack, str, value.op });
    }
};

// ----------------------------------------------------------------------------

test "Op.fromTag" {
    inline for (@typeInfo(Op.Tag).Enum.fields) |variant| {
        const e = @field(Op.Tag, variant.name);
        if (Op.fromTag(e)) |v| {
            try std.testing.expectEqual(e, v);
        } else |_| {}
    }
}
