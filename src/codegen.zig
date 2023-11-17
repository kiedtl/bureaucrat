const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

// const vm = @import("vm.zig");

const StackBufferError = @import("buffer.zig").StackBufferError;

const ASTNode = @import("common.zig").ASTNode;
const ASTNodeList = @import("common.zig").ASTNodeList;
const Program = @import("common.zig").Program;
const Ins = @import("common.zig").Ins;
const Op = @import("common.zig").Op;
const OpTag = @import("common.zig").OpTag;

const WK_STACK = @import("common.zig").WK_STACK;
const RT_STACK = @import("common.zig").RT_STACK;

const gpa = &@import("common.zig").gpa;

const CodegenError = mem.Allocator.Error || StackBufferError;

// UA: Unresolved Address
//
// As we walk through the AST generating bytecode, we store references to
// identifiers in a UAList and insert a dummy null value into the ROM; later on,
// we iterate through the UAList, replacing the dummy values with the real
// references.
//
// The reason for this is that although we know what each identifiers are
// (they were extracted earlier), we don't know where they'll be in the ROM
// until *after* the codegen process.
//
const UA = struct {
    loc: usize,
    ident: []const u8,
    node: *ASTNode,

    pub const List = std.ArrayList(UA);
};

//
//
// -----------------------------------------------------------------------------
//
//

// "emit returning index"
fn emitRI(buf: *Ins.List, node: ?*ASTNode, stack: usize, k: bool, s: bool, op: Op) CodegenError!usize {
    _ = node;
    try buf.append(Ins{ .stack = stack, .op = op, .keep = k, .short = s });
    return buf.items.len - 1;
}

fn emit(buf: *Ins.List, node: ?*ASTNode, stack: usize, k: bool, s: bool, op: Op) CodegenError!void {
    _ = try emitRI(buf, node, stack, k, s, op);
}

fn emitUA(buf: *Ins.List, ual: *UA.List, ident: []const u8, node: *ASTNode) CodegenError!void {
    try emitIMM16(buf, null, 0, false, .Olit, 0);
    try ual.append(.{
        .loc = buf.items.len - 2,
        .ident = ident,
        .node = node,
    });
    switch (node.node) {
        .Call => try emit(buf, null, 0, false, true, .Ojsr),
        else => unreachable,
    }
}

fn emitIMM(buf: *Ins.List, node: ?*ASTNode, stack: usize, k: bool, op: OpTag, imm: u8) CodegenError!void {
    try emit(buf, node, stack, k, false, Op.fromTag(op) catch unreachable);
    try emit(buf, node, stack, k, false, .{ .Oraw = imm });
}

fn emitIMM16(buf: *Ins.List, node: ?*ASTNode, stack: usize, k: bool, op: OpTag, imm: u16) CodegenError!void {
    try emit(buf, node, stack, k, true, Op.fromTag(op) catch unreachable);
    try emit(buf, node, stack, k, false, .{ .Oraw = @intCast(u8, imm >> 8) });
    try emit(buf, node, stack, k, false, .{ .Oraw = @intCast(u8, imm & 0xFF) });
}

fn emitARG16(buf: *Ins.List, node: ?*ASTNode, stack: usize, k: bool, op: OpTag, imm: u16) CodegenError!void {
    try emitIMM16(buf, node, stack, false, .Olit, imm);
    try emit(buf, node, stack, k, true, Op.fromTag(op) catch unreachable);
}

fn genNode(program: *Program, buf: *Ins.List, node: *ASTNode, ual: *UA.List) CodegenError!void {
    switch (node.node) {
        .Cast => {},
        .None => {},
        .Value => |v| try emitIMM(buf, node, WK_STACK, false, .Olit, v.toU8(program)),
        .Mac => {},
        .Decl => |d| {
            node.romloc = buf.items.len;
            for (d.body.items) |*bodynode|
                try genNode(program, buf, bodynode, ual);
            try emit(buf, node, RT_STACK, false, true, .Ojmp);
        },
        .Quote => {
            @panic("unimplemented");
            // (TODO: shouldn't be gen'ing quotes, they need to be made decls
            // by parser code)
            //
            // const quote_jump_addr = buf.items.len;
            // try emit(buf, node, WK_STACK, false, false, .{ .Oj = 0 }); // Dummy value, replaced later
            // const quote_begin_addr = @intCast(u16, buf.items.len);
            // for (q.body.items) |*bodynode|
            //     try genNode(program, buf, bodynode, ual);
            // try emit(buf, node, RT_STACK, false, false, .{ .Oj = null });
            // const quote_end_addr = @intCast(u16, buf.items.len);
            // try emitARG16(buf, node, WK_STACK, false, .Olit, quote_begin_addr);
            // buf.items[quote_jump_addr].op.Oj = quote_end_addr; // Replace dummy value
        },
        .Loop => |l| {
            const loop_begin = @intCast(u16, buf.items.len);
            for (l.body.items) |*bodynode|
                try genNode(program, buf, bodynode, ual);
            switch (l.loop) {
                .Until => |u| {
                    try emit(buf, node, WK_STACK, false, false, .Odup);
                    for (u.cond.items) |*bodynode|
                        try genNode(program, buf, bodynode, ual);
                    try emitIMM(buf, node, WK_STACK, false, .Olit, 0);
                    try emit(buf, node, WK_STACK, false, false, .Oeq);
                    try emitARG16(buf, node, WK_STACK, false, .Ojcn, 0x0100 + loop_begin);
                },
            }
        },
        .Asm => |a| {
            try emit(buf, node, a.stack, a.keep, a.short, a.op);
        },
        .Call => |f| {
            if (for (program.macs.items) |mac| {
                if (mem.eql(u8, mac.node.Mac.name, f.name))
                    break mac;
            } else null) |mac| {
                for (mac.node.Mac.body.items) |*item|
                    try genNode(program, buf, item, ual);
            } else {
                try emitUA(buf, ual, f.name, node);
            }
        },
        .Cond => |cond| {
            var end_jumps = std.ArrayList(usize).init(gpa.allocator()); // Dummy jumps to fix
            defer end_jumps.deinit();

            for (cond.branches.items) |branch| {
                //try emitDUP(buf, WK_STACK);
                try genNodeList(program, buf, branch.cond.items, ual);
                try emitIMM(buf, node, WK_STACK, false, .Olit, 0);
                try emit(buf, node, WK_STACK, false, false, .Oeq);

                try emit(buf, node, WK_STACK, false, false, .Olit);
                const addr_slot = try emitRI(buf, node, WK_STACK, false, false, .{ .Oraw = 0 });
                try emit(buf, node, WK_STACK, false, false, .Ojcn);

                try genNodeList(program, buf, branch.body.items, ual);
                const end_jmp = try emitRI(buf, node, WK_STACK, true, false, .{ .Oraw = 0 });
                try emit(buf, node, WK_STACK, false, false, .Ojmp);
                try end_jumps.append(end_jmp);

                // TODO: overflow checks if body > 256 bytes
                const body_addr = @intCast(u8, buf.items.len - addr_slot);
                buf.items[addr_slot].op.Oraw = body_addr;
            }

            if (cond.else_branch) |branch| {
                try genNodeList(program, buf, branch.items, ual);
            }

            // TODO: remove the very last end jump if there's no else_branch,
            // since it's completely unnecessary

            const cond_end_addr = buf.items.len;
            for (end_jumps.items) |end_jump| {
                buf.items[end_jump].op.Oraw = @intCast(u8, cond_end_addr - end_jump);
            }
        },
    }
}

pub fn genNodeList(program: *Program, buf: *Ins.List, nodes: []ASTNode, ual: *UA.List) CodegenError!void {
    for (nodes) |*node|
        try genNode(program, buf, node, ual);
}

pub fn generate(program: *Program) CodegenError!Ins.List {
    var buf = Ins.List.init(gpa.allocator());
    var ual = UA.List.init(gpa.allocator());

    for (program.ast.items) |*node| {
        try genNode(program, &buf, node, &ual);
    }

    ual_search: for (ual.items) |ua| {
        for (program.defs.items) |def| {
            if (mem.eql(u8, def.node.Decl.name, ua.ident)) {
                const addr = def.romloc + 0x100;
                buf.items[ua.loc + 0].op.Oraw = @intCast(u8, addr >> 8);
                buf.items[ua.loc + 1].op.Oraw = @intCast(u8, addr & 0xFF);
                continue :ual_search;
            }
        }

        // If we haven't matched a UA with a label by now, it's an invalid
        // identifier
        unreachable;
    }

    return buf;
}
