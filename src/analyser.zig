const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const assert = std.debug.assert;

const common = @import("common.zig");

const Program = common.Program;
const ASTNode = common.ASTNode;
const ASTNodeList = common.ASTNodeList;
const TypeInfo = common.TypeInfo;
const Value = common.Value;
const VTList32 = TypeInfo.List32;

pub const BlockAnalysis = struct {
    args: VTList32 = VTList32.init(null),
    stack: VTList32 = VTList32.init(null),
    rargs: VTList32 = VTList32.init(null),
    rstack: VTList32 = VTList32.init(null),

    pub fn conformGenericTo(generic: @This(), caller: *const @This(), p: *const Program) @This() {
        // TODO: do rstack
        if (generic.rstack.len > 0 or generic.rargs.len > 0) @panic("TODO");

        // std.log.info("CONFORM {}", .{generic});
        // std.log.info("TO ARGS {}", .{caller});

        var r = generic;

        for (r.args.slice()) |*arg|
            if (arg.* == .TypeRef) {
                arg.* = r.args.constSlice()[r.args.len - arg.*.TypeRef - 1];
            };

        for (r.stack.slice()) |*stack|
            if (stack.* == .TypeRef) {
                stack.* = r.args.constSlice()[r.args.len - stack.*.TypeRef - 1];
            };

        var i = r.args.len;
        var j: usize = 0;
        while (i > 0) : (j += 1) {
            i -= 1;
            const arg = &r.args.slice()[i];
            const calleritem = if (j < caller.stack.len)
                caller.stack.constSlice()[caller.stack.len - j - 1]
            else if ((j - caller.stack.len) < caller.args.len)
                caller.args.constSlice()[caller.args.len - (j - caller.stack.len) - 1]
            else
                arg.*;
            if (arg.isGeneric()) {
                if (!arg.doesInclude(calleritem, p)) {
                    std.log.err("Generic {} @ {} does not encompass {}", .{ arg, i, calleritem });
                    @panic("whoopsies");
                }
                arg.* = calleritem;
            }
        }

        // std.log.info("RESULTS {}\n\n", .{r});

        return r;
    }

    pub fn eqExact(a: @This(), b: @This()) bool {
        const S = struct {
            pub fn f(_a: VTList32, _b: VTList32) bool {
                if (_a.len != _b.len) return false;
                return for (_a.constSlice(), 0..) |item, i| {
                    if (!item.eq(_b.constSlice()[i])) break false;
                } else true;
            }
        };
        return S.f(a.args, b.args) or S.f(a.rargs, b.rargs) or
            S.f(a.stack, b.stack) or S.f(a.rstack, b.rstack);
    }

    pub fn isGeneric(self: @This()) bool {
        const S = struct {
            pub fn f(list: VTList32) bool {
                return for (list.constSlice()) |item| {
                    if (item.isGeneric()) break true;
                } else false;
            }
        };
        return S.f(self.args) or S.f(self.rargs) or
            S.f(self.stack) or S.f(self.rstack);
    }

    pub fn format(self: @This(), comptime f: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (comptime !mem.eql(u8, f, "")) {
            @compileError("Unknown format string: '" ++ f ++ "'");
        }

        try writer.print("\n    args:   ", .{});
        for (self.args.constSlice()) |i| try writer.print("{s}, ", .{@tagName(i)});
        try writer.print("\n    stack:  ", .{});
        for (self.stack.constSlice()) |i| try writer.print("{s}, ", .{@tagName(i)});
        try writer.print("\n    rargs:  ", .{});
        for (self.rargs.constSlice()) |i| try writer.print("{s}, ", .{@tagName(i)});
        try writer.print("\n    rstack: ", .{});
        for (self.rstack.constSlice()) |i| try writer.print("{s}, ", .{@tagName(i)});
    }

    pub fn mergeInto(self: @This(), b: *@This()) void {
        // std.log.info("MERGE {}", .{self});
        // std.log.info("INTO  {}", .{b});

        if (b.stack.len < self.args.len)
            b.args.insertSlice(
                0,
                self.args.constSlice()[0 .. self.args.len - b.stack.len],
            ) catch unreachable;
        b.stack.resizeTo(b.stack.len -| self.args.len);
        b.stack.appendSlice(self.stack.constSlice()) catch unreachable;

        if (b.rstack.len < self.rargs.len)
            b.rargs.insertSlice(
                0,
                self.rargs.constSlice()[0 .. self.rargs.len - b.rstack.len],
            ) catch unreachable;
        b.rstack.resizeTo(b.rstack.len -| self.rargs.len);
        b.rstack.appendSlice(self.rstack.constSlice()) catch unreachable;

        // std.log.info("RESULT {}\n\n--------------\n", .{b});
    }
};

fn analyseAsm(i: *common.Ins, caller_an: *const BlockAnalysis, prog: *Program) BlockAnalysis {
    var a = BlockAnalysis{};

    const args_needed: usize = switch (i.op) {
        .Ohalt => 0,
        .Odeo, .Odup, .Odrop => 1,
        else => 2,
    };

    const stk = if (i.stack == common.WK_STACK) &caller_an.stack else &caller_an.rstack;
    const a1 = if (stk.len >= 1) stk.constSlice()[stk.len - 1] else null;
    const a2 = if (stk.len >= 2) stk.constSlice()[stk.len - 2] else null;
    const a1b: ?u5 = if (stk.len >= 1) a1.?.bits(prog) else null;
    const a2b: ?u5 = if (stk.len >= 2) a2.?.bits(prog) else null;

    if (i.generic and stk.len >= args_needed and
        ((args_needed == 2 and a1b != null and a2b != null) or
        (args_needed == 1 and a1b != null)))
    {
        i.short = switch (i.op) {
            .Odup, .Odrop, .Odeo => a1b.? == 16,
            else => a1b.? == 16 and a2b.? == 16,
        };
        i.generic = false;
    }

    const any: TypeInfo = if (i.generic) .Any else if (i.short) .Any16 else .Any8;

    switch (i.op) {
        .Odeo => {
            a.args.append(if (i.short) .U16 else .U8) catch unreachable;
            a.stack.append(.U8) catch unreachable; // TODO: device
        },
        .Odup => {
            a.args.append(a1 orelse any) catch unreachable;
            a.stack.append(a1 orelse any) catch unreachable;
        },
        .Odrop => a.args.append(a1 orelse any) catch unreachable,
        .Oeor, .Omul, .Oadd, .Osub => {
            a.args.append(a1 orelse any) catch unreachable;
            a.args.append(a2 orelse any) catch unreachable;
            a.stack.append(a1 orelse any) catch unreachable;
        },
        .Oeq, .Oneq, .Olt, .Ogt => {
            a.args.append(a1 orelse any) catch unreachable;
            a.args.append(a2 orelse any) catch unreachable;
            a.stack.append(.Bool) catch unreachable;
        },
        .Ohalt => {},
        else => {
            std.log.info("{} not implmented", .{i});
            @panic("todo");
        },
        // .Oraw => {}, // TODO: panic and refuse to analyse block
        // .Olit => @panic("todo"), // TODO: panic and refuse to analyse block
        // .Ojmp => a.args.append(.Ptr8) catch unreachable,
        // .Ojcn => {
        //     a.args.append(.Bool) catch unreachable;
        //     a.args.append(.Ptr8) catch unreachable;
        // },
        // .Ojsr => a.rstack.append(.AbsPtr), // FIXME: short mode?
        // .Ostash => {
        //     a.rstack += 1;
        //     a.args += 1;
        // },
        // .Osr, .Ozj, .Onac, .Oroll, .Odmod => unreachable,
    }

    if (i.keep) a.args.clear();
    if (i.keep) a.rargs.clear();

    if (i.stack == common.RT_STACK) {
        const tmp = a.args;
        a.args = a.rargs;
        a.rargs = tmp;

        const stmp = a.stack;
        a.stack = a.rstack;
        a.rstack = stmp;
    }

    return a;
}

fn analyseBlock(program: *Program, parent: *ASTNode.Decl, block: ASTNodeList, a: *BlockAnalysis) void {
    // std.log.info("*** analysing {s}", .{parent.name});
    var iter = block.iterator();
    while (iter.next()) |node| {
        // std.log.info("node: {}", .{node.node});
        switch (node.node) {
            .None => {},
            .Mac, .Decl => unreachable,
            .Call => |*c| switch (c.ctyp) {
                .Decl => {
                    const d = for (program.defs.items) |decl| {
                        if (mem.eql(u8, decl.node.Decl.name, c.name))
                            break decl;
                    } else unreachable;

                    if (d.node.Decl.arity == null and !d.node.Decl.is_analysed) {
                        analyseBlock(program, &d.node.Decl, d.node.Decl.body, &d.node.Decl.analysis);
                        d.node.Decl.is_analysed = true;
                    }

                    const analysis = d.node.Decl.arity orelse d.node.Decl.analysis;

                    if (a.isGeneric() or !analysis.isGeneric()) {
                        analysis.mergeInto(a);
                        d.node.Decl.calls += 1;
                    } else if (analysis.isGeneric()) {
                        const ungenericified = analysis.conformGenericTo(a, program);
                        const var_ind: ?usize = for (d.node.Decl.variations.slice(), 0..) |an, i| {
                            if (ungenericified.eqExact(an)) break i;
                        } else null;
                        if (var_ind == null)
                            d.node.Decl.variations.append(ungenericified) catch unreachable;
                        c.ctyp.Decl = (var_ind orelse d.node.Decl.variations.len - 1) + 1;

                        ungenericified.mergeInto(a);

                        if (var_ind == null) {
                            const newdef_ = d.deepclone();
                            const newdef = program.ast.appendAndReturn(newdef_) catch unreachable;
                            program.defs.append(newdef) catch unreachable;

                            newdef.node.Decl.variant = d.node.Decl.variations.len;
                            newdef.node.Decl.arity = ungenericified;

                            var ab = BlockAnalysis{};
                            for (ungenericified.args.constSlice()) |arg|
                                ab.stack.append(arg) catch unreachable;
                            analyseBlock(program, &newdef.node.Decl, newdef.node.Decl.body, &ab);
                            newdef.node.Decl.is_analysed = true;

                            newdef.node.Decl.calls += 1;
                        }
                    }
                },
                .Mac => {
                    const m = for (program.defs.items) |mac| {
                        if (mem.eql(u8, mac.node.Mac.name, c.name))
                            break mac;
                    } else unreachable;
                    if (!m.node.Mac.is_analysed) {
                        analyseBlock(program, parent, m.node.Mac.body, &m.node.Mac.analysis);
                        m.node.Mac.is_analysed = true;
                    }
                    m.node.Mac.analysis.mergeInto(a);
                },
                .Unchecked => unreachable, // parser.postProcess missed something
            },
            .Loop => |l| {
                switch (l.loop) {
                    .Until => |u| analyseBlock(program, parent, u.cond, a),
                }
                analyseBlock(program, parent, l.body, a);
            },
            .When => {
                // TODO: assert that body doesn't result in change to stack, or
                // that body and else result in same change

                var whena = BlockAnalysis{};
                whena.args.append(.Bool) catch unreachable;
                whena.mergeInto(a);
            },
            .Cond => {
                @panic("TODO");
                // Outline:
                // - Check first branch, don't merge analysis
                // - Check every other branch block, assert they're all the same
                //   - Analyse else branch also
                // - Check condition blocks, assert they're all identical
                // - Finally, merge one condition block, and one main block
            },
            .Asm => |*i| {
                // std.log.info("merging asm into main", .{});
                analyseAsm(i, a, program).mergeInto(a);
            },
            .Value => |v| a.stack.append(v.typ) catch unreachable,
            .Quote => a.stack.append(TypeInfo.ptr16(program, .Quote, 1)) catch unreachable,
            .Cast => |*c| {
                const typ = switch (c.to) {
                    .builtin => |b| b,
                    .ref => |r| parent.arity.?.args.constSlice()[r],
                };

                var casta = BlockAnalysis{};
                casta.args.append(.Any) catch unreachable;
                casta.stack.append(typ) catch unreachable;
                casta.mergeInto(a);

                c.to = .{ .builtin = typ };
                c.of = a.stack.last() orelse .Any; // FIXME
            },
        }
    }
}

pub fn analyse(program: *Program) void {
    // for (program.defs.items) |decl_node| {
    //     const decl = &decl_node.node.Decl;
    //     if (!decl.is_analysed) {
    //         analyseBlock(program, decl, decl.body, &decl_node.node.Decl.analysis);
    //         decl.is_analysed = true;
    //     }
    // }

    const entrypoint_node = for (program.defs.items) |decl_node| {
        if (mem.eql(u8, decl_node.node.Decl.name, "_Start")) break decl_node;
    } else unreachable;
    const entrypoint = &entrypoint_node.node.Decl;
    entrypoint.calls += 1;

    assert(!entrypoint.is_analysed);
    entrypoint.is_analysed = true;
    analyseBlock(program, entrypoint, entrypoint.body, &entrypoint.analysis);
}
