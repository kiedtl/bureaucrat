const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const activeTag = std.meta.activeTag;

const common = @import("common.zig");
const lexer = @import("lexer.zig");
const utils = @import("utils.zig");

const BlockAnalysis = @import("analyser.zig").BlockAnalysis;
const ASTNode = @import("common.zig").ASTNode;
const TypeInfo = common.TypeInfo;
const Value = common.Value;
const ASTNodeList = @import("common.zig").ASTNodeList;
const ASTNodePtrList = @import("common.zig").ASTNodePtrList;
const Program = @import("common.zig").Program;
const Op = @import("common.zig").Op;

const WK_STACK = @import("common.zig").WK_STACK;
const RT_STACK = @import("common.zig").RT_STACK;

pub const Parser = struct {
    program: Program,
    alloc: mem.Allocator,

    const ParserError = error{
        StrayToken,
        EmptyList,
        ExpectedKeyword,
        ExpectedEnumLit,
        ExpectedOptionalNumber,
        ExpectedString,
        ExpectedItems,
        ExpectedNode,
        UnexpectedItems,
        ExpectedValue,
        ExpectedStatement,
        UnknownKeyword,
        UnexpectedLabelDefinition,
        InvalidAsmOp,
        InvalidAsmFlag,
        InvalidType,
        MissingEnumType,
        NotAnEnum,
        InvalidEnumField,
        NoSuchType,
        UnknownIdent,
    } || mem.Allocator.Error;

    pub fn init(alloc: mem.Allocator) Parser {
        return .{
            .program = Program{
                .ast = ASTNodeList.init(alloc),
                .defs = ASTNodePtrList.init(alloc),
                .macs = ASTNodePtrList.init(alloc),
                .types = common.Type.AList.init(alloc),
                .builtin_types = std.ArrayList(TypeInfo).init(alloc),
                //.defs = ASTNodeList.init(alloc),
            },
            .alloc = alloc,
        };
    }

    pub fn initTypes(self: *Parser) void {
        self.program.addNativeType(common.Op.Tag, "Op");
    }

    fn validateListLength(ast: []const lexer.Node, require: usize) ParserError!void {
        if (ast.len < require) return error.ExpectedItems;
        if (ast.len > require) return error.UnexpectedItems;
    }

    fn expectNode(comptime nodetype: meta.Tag(lexer.Node.NodeType), node: *const lexer.Node) b: {
        break :b ParserError!@TypeOf(@field(node.node, @tagName(nodetype)));
    } {
        if (node.node != nodetype) {
            return error.ExpectedNode;
        }
        return @field(node.node, @tagName(nodetype));
    }

    fn parseValue(self: *Parser, node: *const lexer.Node) ParserError!Value {
        _ = self;
        return switch (node.node) {
            .T => .{ .typ = .Bool, .val = .{ .u8 = 1 } },
            .Nil => .{ .typ = .Bool, .val = .{ .u8 = 0 } },
            .Number => |n| .{ .typ = .U8, .val = .{ .u8 = n } },
            .Codepoint => |c| .{ .typ = .Codepoint, .val = .{ .u8 = c } },
            .String => |s| .{ .typ = .String, .val = .{ .String = s } },
            .EnumLit => |e| .{ .typ = .AmbigEnumLit, .val = .{ .AmbigEnumLit = e } },
            else => error.ExpectedValue,
        };
    }

    fn parseStatement(self: *Parser, node: *const lexer.Node) ParserError!ASTNode {
        return switch (node.node) {
            .List => |l| try self.parseList(l.items),
            .Quote => |q| blk: {
                const body = try self.parseStatements(q.items);
                break :blk ASTNode{
                    .node = .{ .Quote = .{ .body = body } },
                    .srcloc = node.location,
                };
            },
            .Keyword => |i| b: {
                if (mem.eql(u8, i, "return")) {
                    break :b ASTNode{ .node = .Return, .srcloc = node.location };
                }
                break :b ASTNode{ .node = .{ .Call = .{ .name = i } }, .srcloc = node.location };
            },
            .Child => @panic("TODO"),
            else => ASTNode{ .node = .{ .Value = try self.parseValue(node) }, .srcloc = node.location },
        };
    }

    fn parseStatements(self: *Parser, nodes: []const lexer.Node) ParserError!ASTNodeList {
        var ast = ASTNodeList.init(self.alloc);
        for (nodes) |node|
            try ast.append(try self.parseStatement(&node));
        return ast;
    }

    fn parseList(self: *Parser, ast: []const lexer.Node) ParserError!ASTNode {
        if (ast.len == 0)
            return error.EmptyList;

        return switch (ast[0].node) {
            .Keyword => |k| b: {
                if (mem.eql(u8, k, "word")) {
                    const name = try expectNode(.Keyword, &ast[1]);

                    var arity: ?BlockAnalysis = null;
                    if (ast.len == 4) {
                        arity = BlockAnalysis{};
                        var norm_stack = true;
                        var before = true;
                        const ast_arity = try expectNode(.List, &ast[2]);
                        for (ast_arity.items) |*arity_item| {
                            var dst: *TypeInfo.List32 = undefined;
                            if (before) {
                                dst = if (norm_stack) &arity.?.args else &arity.?.rargs;
                            } else {
                                dst = if (norm_stack) &arity.?.stack else &arity.?.rstack;
                            }

                            switch (arity_item.node) {
                                .VarNum => |arity_ref| {
                                    dst.append(.{ .TypeRef = arity_ref }) catch unreachable;
                                },
                                .Keyword => |item| {
                                    if (mem.eql(u8, item, "--")) {
                                        before = false;
                                    } else if (mem.eql(u8, item, "|")) {
                                        norm_stack = false;
                                    } else if (meta.stringToEnum(TypeInfo.Tag, item)) |p| {
                                        // FIXME: fails silently
                                        // Will fix once type values are fully fleshed out
                                        // (Including (Ptr8), (Ptr16), (Enum), etc
                                        inline for (meta.fields(TypeInfo)) |field|
                                            if (field.type == void and
                                                mem.eql(u8, field.name, @tagName(p)))
                                            {
                                                dst.append(
                                                    @unionInit(TypeInfo, field.name, {}),
                                                ) catch unreachable;
                                            };
                                    } else {
                                        std.log.err("Invalid type in arity def: {s}", .{item});
                                        return error.InvalidType;
                                    }
                                },
                                else => return error.ExpectedNode,
                            }
                        }
                    }

                    const body_ind: usize = if (ast.len == 4) @as(usize, 3) else 2;
                    const ast_body = try expectNode(.Quote, &ast[body_ind]);
                    const body = try self.parseStatements(ast_body.items);

                    break :b ASTNode{ .node = .{ .Decl = .{
                        .name = name,
                        .arity = arity,
                        .body = body,
                    } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "mac")) {
                    const name = try expectNode(.Keyword, &ast[1]);

                    const ast_body = try expectNode(.Quote, &ast[2]);
                    const body = try self.parseStatements(ast_body.items);

                    break :b ASTNode{
                        .node = .{ .Mac = .{ .name = name, .body = body } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "as")) {
                    try validateListLength(ast, 2);

                    switch (ast[1].node) {
                        .VarNum => |n| break :b ASTNode{
                            .node = .{ .Cast = .{ .to = .{ .ref = n } } },
                            .srcloc = ast[0].location,
                        },
                        // .EnumLit => {
                        //     const typ_kwd = try self.parseValue(&ast[1]);
                        //     if (typ_kwd != .AmbigEnumLit)
                        //         return error.ExpectedEnumLit;
                        //     const typ_lowered = try self.lowerEnumValue(typ_kwd.AmbigEnumLit);
                        //     const typ = meta.stringToEnum(ASTValue.Tag, self.program.types.items[typ_lowered.type].def.Enum.fields.items[typ_lowered.field].name) orelse return error.InvalidType;
                        //     break :b ASTNode{
                        //         .node = .{ .Cast = .{ .builtin = typ } },
                        //         .srcloc = ast[0].location,
                        //     };
                        // },
                        else => return error.ExpectedNode,
                    }
                } else if (mem.eql(u8, k, "return")) {
                    try validateListLength(ast, 1);
                    break :b ASTNode{ .node = .Return, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "until")) {
                    try validateListLength(ast, 3);

                    const ast_cond = try expectNode(.Quote, &ast[1]);
                    const cond = try self.parseStatements(ast_cond.items);

                    const ast_body = try expectNode(.Quote, &ast[2]);
                    const body = try self.parseStatements(ast_body.items);

                    break :b ASTNode{
                        .node = .{ .Loop = .{
                            .loop = .{ .Until = .{ .cond = cond } },
                            .body = body,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "when")) {
                    const yup = try self.parseStatements((try expectNode(.Quote, &ast[1])).items);
                    const nah = if (ast.len > 2) try self.parseStatements((try expectNode(.Quote, &ast[2])).items) else null;
                    break :b ASTNode{
                        .node = .{ .When = .{ .yup = yup, .nah = nah } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "cond")) {
                    var cond_node = ASTNode.Cond{
                        .branches = ASTNode.Cond.Branch.List.init(self.alloc),
                        .else_branch = null,
                    };

                    var all_branches = std.ArrayList(ASTNodeList).init(self.alloc);
                    defer all_branches.deinit();

                    for (ast[1..]) |*node| {
                        const q = try expectNode(.Quote, node);
                        try all_branches.append(try self.parseStatements(q.items));
                    }

                    // FIXME: make it an error for a cond statement with only
                    // one argument

                    var i: usize = 0;
                    while (i < all_branches.items.len) : (i += 2) {
                        if (i == all_branches.items.len - 1) {
                            cond_node.else_branch = all_branches.items[i];
                        } else {
                            const cond = all_branches.items[i + 0];
                            const body = all_branches.items[i + 1];
                            try cond_node.branches.append(ASTNode.Cond.Branch{
                                .cond = cond,
                                .body = body,
                            });
                        }
                    }

                    break :b ASTNode{
                        .node = .{ .Cond = cond_node },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "asm")) {
                    try validateListLength(ast, 3);

                    const asm_flags = try self.parseValue(&ast[1]);
                    if (asm_flags.typ != .String)
                        return error.ExpectedString;

                    var asm_stack: usize = WK_STACK;
                    var asm_keep = false;
                    var asm_short = false;
                    var asm_generic = false;
                    if (asm_flags.typ == .String) {
                        for (asm_flags.val.String.items) |char| switch (char) {
                            'k' => asm_keep = true,
                            'r' => asm_stack = RT_STACK,
                            's' => asm_short = true,
                            'g' => asm_generic = true,
                            else => return error.InvalidAsmFlag,
                        };
                    }

                    const asm_op_kwd = try self.parseValue(&ast[2]);
                    if (asm_op_kwd.typ != .AmbigEnumLit)
                        return error.ExpectedEnumLit;
                    const asm_op_lowered = try self.lowerEnumValue(asm_op_kwd.val.AmbigEnumLit);
                    const asm_op_e = meta.stringToEnum(
                        Op.Tag,
                        self.program.types.items[asm_op_lowered.type].def.Enum.fields.items[asm_op_lowered.field].name,
                    ) orelse return error.InvalidAsmOp;
                    const asm_op = Op.fromTag(asm_op_e) catch return error.InvalidAsmOp;
                    break :b ASTNode{
                        .node = .{ .Asm = .{ .stack = asm_stack, .short = asm_short, .keep = asm_keep, .op = asm_op } },
                        .srcloc = ast[0].location,
                    };
                } else {
                    std.log.info("Unknown keyword: {s}", .{k});
                    break :b error.UnknownKeyword;
                }
            },
            .List => |l| try self.parseList(l.items),
            else => try self.parseStatement(&ast[0]),
        };
    }

    // Extract definitions
    pub fn extractDefs(self: *Parser) ParserError!void {
        var iter = self.program.ast.iterator();
        while (iter.next()) |node|
            if (node.node == .Decl) {
                try self.program.defs.append(node);
            } else if (node.node == .Mac) {
                try self.program.macs.append(node);
            };
    }

    pub fn lowerEnumValue(self: *Parser, lit: lexer.Node.EnumLit) ParserError!TypeInfo.EnumLit {
        if (lit.of == null)
            return error.MissingEnumType;
        for (self.program.types.items, 0..) |t, i| {
            if (mem.eql(u8, t.name, lit.of.?)) {
                if (t.def != .Enum)
                    return error.NotAnEnum;
                for (t.def.Enum.fields.items, 0..) |field, field_i| {
                    if (mem.eql(u8, field.name, lit.v)) {
                        return TypeInfo.EnumLit{ .type = i, .field = field_i };
                    }
                }
                return error.InvalidEnumField;
            }
        }
        return error.NoSuchType;
    }

    // Earlier we couldn't know what type an Enum literal belonged to. At this
    // stage we find and set that information.
    //
    // Also check calls to determine what type they are.
    pub fn postProcess(self: *Parser) ParserError!void {
        const _S = struct {
            pub fn walkNodes(parser: *Parser, nodes: ASTNodeList) ParserError!void {
                var iter = nodes.iterator();
                while (iter.next()) |node|
                    try walkNode(parser, node);
            }

            pub fn walkNode(parser: *Parser, node: *ASTNode) ParserError!void {
                switch (node.node) {
                    .Value => |v| switch (v.typ) {
                        .AmbigEnumLit => {
                            const lowered = try parser.lowerEnumValue(v.val.AmbigEnumLit);
                            node.node = .{ .Value = .{ .typ = .{ .EnumLit = lowered.type }, .val = .{ .EnumLit = lowered } } };
                        },
                        else => {},
                    },
                    .Decl => |d| try walkNodes(parser, d.body),
                    .Quote => |d| try walkNodes(parser, d.body),
                    .Loop => |d| {
                        switch (d.loop) {
                            .Until => |u| try walkNodes(parser, u.cond),
                        }
                        try walkNodes(parser, d.body);
                    },
                    .When => |when| {
                        try walkNodes(parser, when.yup);
                        if (when.nah) |n| try walkNodes(parser, n);
                    },
                    .Cond => |cond| {
                        for (cond.branches.items) |branch| {
                            try walkNodes(parser, branch.cond);
                            try walkNodes(parser, branch.body);
                        }
                        if (cond.else_branch) |branch|
                            try walkNodes(parser, branch);
                    },
                    .Call => |c| if (c.ctyp == .Unchecked) {
                        if (for (parser.program.macs.items) |mac| {
                            if (mem.eql(u8, mac.node.Mac.name, c.name))
                                break true;
                        } else false) {
                            node.node.Call.ctyp = .Mac;
                        } else if (for (parser.program.defs.items) |decl| {
                            if (mem.eql(u8, decl.node.Decl.name, c.name))
                                break true;
                        } else false) {
                            node.node.Call.ctyp = .{ .Decl = 0 };
                        } else {
                            std.log.info("Unknown ident {s}", .{c.name});
                            return error.UnknownIdent;
                        }
                    },
                    else => {},
                }
            }
        };
        try _S.walkNodes(self, self.program.ast);
    }

    // Setup the entry function
    // TODO: this should be in codegen
    //
    pub fn setupMainFunc(self: *Parser) ParserError!void {
        var body = ASTNodeList.init(self.alloc);
        var iter2 = self.program.ast.iterator();
        while (iter2.next()) |ast_item| {
            if (ast_item.node != .Decl and ast_item.node != .Mac) {
                try body.append(ast_item.*);
                ast_item.node = .None;
                ast_item.srcloc = 0;
            }
        }
        try body.append(ASTNode{ .node = .{
            .Asm = .{ .stack = WK_STACK, .op = .Ohalt },
        }, .srcloc = 0 });
        try self.program.ast.insertAtInd(0, ASTNode{ .node = .{ .Call = .{
            .name = "_Start",
            .goto = true,
        } }, .srcloc = 0 });
        try self.program.ast.append(ASTNode{
            .node = .{ .Decl = .{ .name = "_Start", .body = body } },
            .srcloc = 0,
        });
    }

    pub fn parse(self: *Parser, lexed: *const lexer.NodeList) ParserError!Program {
        for (lexed.items) |*node| switch (node.node) {
            .List => |l| try self.program.ast.append(try self.parseList(l.items)),
            else => try self.program.ast.append(try self.parseStatement(node)),
        };

        try self.setupMainFunc();
        try self.extractDefs();
        try self.postProcess();

        return self.program;
    }
};
