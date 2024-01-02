const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const activeTag = std.meta.activeTag;
const assert = std.debug.assert;

const common = @import("common.zig");
const lexer = @import("lexer.zig");
const utils = @import("utils.zig");

const StackBuffer = @import("buffer.zig").StackBuffer;
const BlockAnalysis = @import("analyser.zig").BlockAnalysis;
const ASTNode = @import("common.zig").ASTNode;
const TypeInfo = common.TypeInfo;
const Value = common.Value;
const Srcloc = common.Srcloc;
const Scope = common.Scope;
const ASTNodeList = @import("common.zig").ASTNodeList;
const ASTNodePtrList = @import("common.zig").ASTNodePtrList;
const Program = @import("common.zig").Program;
const Op = @import("common.zig").Op;
const ErrorSet = @import("common.zig").Error.Set;
const UserType = @import("common.zig").UserType;

const WK_STACK = @import("common.zig").WK_STACK;
const RT_STACK = @import("common.zig").RT_STACK;

pub const Parser = struct {
    program: *Program,
    alloc: mem.Allocator,
    is_testing: bool = false,
    stuff_to_import: bool = false,

    pub const ParserError = error{
        StrayToken,
        EmptyList,
        ExpectedNum,
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
        UnknownLocal,
        UnexpectedLabelDefinition,
        InvalidAsmOp,
        InvalidAsmFlag,
        InvalidType,
        InvalidFieldType,
        MissingEnumType,
        NotAnEnumOrDevice,
        InvalidEnumField,
        NoSuchType,
        UnknownIdent,
        NakedStatements,
        NoMainFunction,
        InvalidCall,
        InvalidImport,
        InvalidMetadata,
    } || mem.Allocator.Error || std.fs.File.GetSeekPosError || std.fs.File.ReadError;

    pub fn init(program: *Program, is_testing: bool, alloc: mem.Allocator) Parser {
        program.addNativeType(common.Op.Tag, "Op");
        return .{
            .program = program,
            .alloc = alloc,
            .is_testing = is_testing,
        };
    }

    fn validateListLength(self: *Parser, ast: []const lexer.Node, require: usize) ParserError!void {
        if (ast.len < require)
            return self.program.perr(error.ExpectedItems, ast[0].location);
        if (ast.len > require)
            return self.program.perr(error.UnexpectedItems, ast[0].location);
    }

    fn expectNode(self: *Parser, comptime nodetype: meta.Tag(lexer.Node.NodeType), node: *const lexer.Node) b: {
        break :b ParserError!@TypeOf(@field(node.node, @tagName(nodetype)));
    } {
        if (node.node != nodetype) {
            return self.program.perr(error.ExpectedNode, node.location);
        }
        return @field(node.node, @tagName(nodetype));
    }

    fn parseValue(self: *Parser, node: *const lexer.Node) ParserError!Value {
        return switch (node.node) {
            .T => .{ .typ = .Bool, .val = .{ .u8 = 1 } },
            .Nil => .{ .typ = .Bool, .val = .{ .u8 = 0 } },
            .U8 => |n| .{ .typ = .U8, .val = .{ .u8 = n } },
            .U16 => |n| .{ .typ = .U16, .val = .{ .u16 = n } },
            .I8 => |n| .{ .typ = .I8, .val = .{ .u8 = @bitCast(n) } },
            .I16 => |n| .{ .typ = .I16, .val = .{ .u16 = @bitCast(n) } },
            .Char8 => |c| .{ .typ = .Char8, .val = .{ .u8 = c } },
            .Char16 => |c| .{ .typ = .Char16, .val = .{ .u16 = c } },
            .String => |s| b: {
                self.program.statics.append(.{
                    .type = .Char8,
                    .count = s.items.len + 1,
                    .default = .{ .String = s },
                }) catch unreachable;
                break :b .{
                    .typ = .{ .StaticPtr = self.program.statics.items.len - 1 },
                    .val = .None,
                };
            },
            .EnumLit => |e| .{ .typ = .AmbigEnumLit, .val = .{ .AmbigEnumLit = e } },
            else => self.program.perr(error.ExpectedValue, node.location),
        };
    }

    fn parseArity(self: *Parser, node: *const lexer.Node) ParserError!BlockAnalysis {
        var arity = BlockAnalysis{};
        var norm_stack = true;
        var before = true;

        const ast_arity = (try self.expectNode(.List, node)).body;
        for (ast_arity.items) |*arity_item| {
            var dst: *TypeInfo.List16 = undefined;
            if (before) {
                dst = if (norm_stack) &arity.args else &arity.rargs;
            } else {
                dst = if (norm_stack) &arity.stack else &arity.rstack;
            }

            if (arity_item.node == .Keyword and mem.eql(u8, arity_item.node.Keyword, "--")) {
                assert(before);
                before = false;
            } else if (arity_item.node == .Keyword and mem.eql(u8, arity_item.node.Keyword, "|")) {
                before = true;
                norm_stack = false;
            } else {
                dst.append(try self.parseType(arity_item)) catch unreachable;
            }
        }

        return arity;
    }

    fn parseType(self: *Parser, node: *const lexer.Node) ParserError!TypeInfo {
        return switch (node.node) {
            .VarNum => |n| .{ .TypeRef = .{ .n = n } },
            .Keyword => |item| b: {
                if (meta.stringToEnum(TypeInfo.Tag, item)) |p| {
                    var r: ?TypeInfo = null;
                    inline for (meta.fields(TypeInfo)) |field|
                        if (field.type == void and
                            mem.eql(u8, field.name, @tagName(p)))
                        {
                            r = @unionInit(TypeInfo, field.name, {});
                        };
                    if (r) |ret| {
                        break :b ret;
                    } else {
                        return self.program.perr(error.InvalidType, node.location);
                    }
                } else {
                    break :b TypeInfo{ .Unresolved = .{
                        .ident = item,
                        .srcloc = node.location,
                    } };
                }
            },
            .List => |lst_obj| {
                const lst = lst_obj.body;
                if (lst.items.len == 0)
                    return error.EmptyList;

                if (lst.items[0].node != .Keyword)
                    return self.program.perr(error.ExpectedKeyword, node.location);

                const k = lst.items[0].node.Keyword;
                var r: ?TypeInfo = null;
                inline for (meta.fields(TypeInfo.Expr)) |field|
                    if (mem.eql(u8, field.name, k))
                        if (@field(TypeInfo.Expr.Tag, field.name) == .Of) {
                            const of = self.program.btype(try self.parseType(&lst.items[1]));
                            const buf = common.gpa.allocator()
                                .create(StackBuffer(usize, 16)) catch unreachable;
                            buf.reinit(null);
                            for (lst.items[2..]) |item|
                                buf.append(
                                    self.program.btype(try self.parseType(&item)),
                                ) catch unreachable;
                            r = .{ .Expr = @unionInit(TypeInfo.Expr, field.name, .{
                                .of = of,
                                .args = buf,
                            }) };
                        } else if (@field(TypeInfo.Expr.Tag, field.name) == .AnySet) {
                            const buf = common.gpa.allocator()
                                .create(StackBuffer(TypeInfo, 8)) catch unreachable;
                            buf.reinit(null);
                            for (lst.items[1..]) |item|
                                buf.append(try self.parseType(&item)) catch unreachable;
                            r = .{ .Expr = @unionInit(TypeInfo.Expr, field.name, .{
                                .set = buf,
                            }) };
                        } else if (@field(TypeInfo.Expr.Tag, field.name) == .FieldType or
                            @field(TypeInfo.Expr.Tag, field.name) == .Omit)
                        {
                            const of = self.program.btype(try self.parseType(&lst.items[1]));
                            const fld = try self.expectNode(.Keyword, &lst.items[2]);
                            r = .{ .Expr = @unionInit(TypeInfo.Expr, field.name, .{
                                .of = of,
                                .field = fld,
                            }) };
                        } else if (@field(TypeInfo.Expr.Tag, field.name) == .Array) {
                            @panic("Must use []/@[] syntax for arrays");
                        } else {
                            const arg = self.program.btype(try self.parseType(&lst.items[1]));
                            r = .{ .Expr = @unionInit(TypeInfo.Expr, field.name, arg) };
                        };
                return r orelse self.program.perr(error.InvalidType, node.location);
            },
            .Quote => |lst| {
                if (lst.items.len == 0)
                    return self.program.perr(error.ExpectedItems, node.location);
                if (lst.items.len > 2)
                    return self.program.perr(error.UnexpectedItems, node.location);

                const t = try self.parseType(&lst.items[0]);
                var count: ?u16 = null;

                if (lst.items.len > 1)
                    count = switch (lst.items[1].node) {
                        .U8 => |u| u,
                        .U16 => |u| u,
                        else => return self.program.perr(error.ExpectedNum, lst.items[1].location),
                    };
                return .{ .Expr = .{ .Array = .{
                    .typ = self.program.btype(t),
                    .count = count,
                } } };
            },
            .At => |subnode| {
                return .{ .Expr = .{ .Ptr16 = self.program.btype(try self.parseType(subnode)) } };
            },
            else => return self.program.perr(error.ExpectedNode, node.location),
        };
    }

    fn parseStatement(self: *Parser, node: *const lexer.Node, p_scope: *Scope) ParserError!ASTNode {
        return switch (node.node) {
            .List => |l| {
                return self.parseList(l.body.items, l.metadata.items, p_scope);
            },
            .Quote => |q| blk: {
                const body = try self.parseStatements(q.items, p_scope);
                break :blk ASTNode{
                    .node = .{ .Quote = .{ .body = body } },
                    .srcloc = node.location,
                };
            },
            .Keyword => |i| b: {
                if (mem.eql(u8, i, "return")) {
                    break :b ASTNode{ .node = .Return, .srcloc = node.location };
                } else if (mem.eql(u8, i, "here")) {
                    break :b ASTNode{ .node = .Here, .srcloc = node.location };
                } else if (mem.eql(u8, i, "debug")) {
                    break :b ASTNode{ .node = .Debug, .srcloc = node.location };
                }
                break :b ASTNode{ .node = .{ .Call = .{ .name = i } }, .srcloc = node.location };
            },
            .MethodCall => |m| b: {
                break :b ASTNode{ .node = .{ .Call = .{ .name = m, .is_method = true } }, .srcloc = node.location };
            },
            .Child => |s| ASTNode{
                .node = .{ .GetChild = .{ .name = s } },
                .srcloc = node.location,
            },
            .ChildNum => |n| ASTNode{
                .node = .{ .GetIndex = .{ .ind = .{ .known = n } } },
                .srcloc = node.location,
            },
            .ChildAmbig => ASTNode{
                .node = .{ .GetIndex = .{ .ind = .stk_unresolved } },
                .srcloc = node.location,
            },
            .At => |atsub| switch (atsub.node) {
                .Keyword => |s| ASTNode{
                    .node = .{ .VRef = .{ .name = s } },
                    .srcloc = node.location,
                },
                else => @panic("@ can only be used on keywords, unless in type expression"),
            },
            .Var => |s| ASTNode{
                .node = .{ .VDeref = .{ .name = s } },
                .srcloc = node.location,
            },
            else => ASTNode{ .node = .{
                .Value = .{ .val = try self.parseValue(node) },
            }, .srcloc = node.location },
        };
    }

    fn parseStatements(self: *Parser, nodes: []const lexer.Node, p_scope: *Scope) ParserError!ASTNodeList {
        var ast = ASTNodeList.init(self.alloc);
        for (nodes) |node|
            try ast.append(try self.parseStatement(&node, p_scope));
        return ast;
    }

    fn parseStructDecl(self: *Parser, ast: []const lexer.Node) ParserError!ASTNode {
        const name = try self.expectNode(.Keyword, &ast[1]);
        const args = if (ast[2].node == .List) b: {
            const list = (self.expectNode(.List, &ast[2]) catch unreachable).body;
            var buff = TypeInfo.List16.init(null);
            for (list.items) |item| {
                const t = try self.parseType(&item);
                if (!t.isGeneric(self.program))
                    @panic("you put this as an arg? really?");
                buff.append(t) catch unreachable;
            }
            break :b buff;
        } else null;
        var fields = ASTNode.TypeDef.Field.AList.init(self.alloc);
        for (if (args == null) ast[2..] else ast[3..]) |node| {
            const fielddef = try self.expectNode(.Quote, &node);
            try self.validateListLength(fielddef.items, 2);
            const fieldnam = try self.expectNode(.Keyword, &fielddef.items[0]);
            const fieldtyp = try self.parseType(&fielddef.items[1]);
            fields.append(.{
                .name = fieldnam,
                .type = fieldtyp,
                .srcloc = node.location,
            }) catch unreachable;
        }
        return ASTNode{
            .node = .{ .TypeDef = .{
                .name = name,
                .def = .{ .Struct = .{ .args = args, .fields = fields } },
            } },
            .srcloc = ast[0].location,
        };
    }

    fn parseTypeDecl(self: *Parser, ast: []const lexer.Node, metadata: []const lexer.Node) ParserError!ASTNode {
        assert(ast[0].node == .Keyword);
        const k = ast[0].node.Keyword;

        var parsed: ASTNode = undefined;

        if (mem.eql(u8, k, "device")) {
            const name = try self.expectNode(.Keyword, &ast[1]);
            const addr = try self.expectNode(.U8, &ast[2]);
            var fields = ASTNode.TypeDef.Field.AList.init(self.alloc);
            for (ast[3..]) |node| {
                const fielddef = try self.expectNode(.Quote, &node);
                try self.validateListLength(fielddef.items, 2);
                const fieldname = try self.expectNode(.Keyword, &fielddef.items[0]);
                const fieldtype = try self.parseType(&fielddef.items[1]);
                if (fieldtype.bits(self.program) == null)
                    return self.program.perr(error.InvalidFieldType, node.location);
                fields.append(.{
                    .name = fieldname,
                    .type = fieldtype,
                    .srcloc = node.location,
                }) catch unreachable;
            }
            parsed = ASTNode{
                .node = .{ .TypeDef = .{
                    .name = name,
                    .def = .{ .Device = .{ .start = addr, .fields = fields } },
                } },
                .srcloc = ast[0].location,
            };
        } else if (mem.eql(u8, k, "struct")) {
            parsed = try self.parseStructDecl(ast);
        } else if (mem.eql(u8, k, "typealias")) {
            const name = try self.expectNode(.Keyword, &ast[1]);
            const val = try self.parseType(&ast[2]);
            parsed = ASTNode{
                .node = .{ .TypeDef = .{
                    .name = name,
                    .def = .{ .Alias = .{ .val = val } },
                } },
                .srcloc = ast[0].location,
            };
        } else unreachable;

        for (metadata) |item| switch (item.node.Metadata.node) {
            .Keyword => |kwd| {
                if (mem.eql(u8, kwd, "private")) {
                    parsed.node.TypeDef.is_private = true;
                } else {
                    return self.program.perr(error.InvalidMetadata, item.location);
                }
            },
            else => {
                return self.program.perr(error.InvalidMetadata, item.location);
            },
        };

        return parsed;
    }

    fn parseList(self: *Parser, ast: []const lexer.Node, metadata: []const lexer.Node, p_scope: *Scope) ParserError!ASTNode {
        if (ast.len == 0)
            return error.EmptyList;

        return switch (ast[0].node) {
            .Keyword => |k| b: {
                if (mem.eql(u8, k, "word")) {
                    const name = try self.expectNode(.Keyword, &ast[1]);

                    var is_method: ?TypeInfo = null;
                    var is_private: bool = false;
                    var is_inline: common.ASTNode.Decl.Inline = .Auto;

                    for (metadata) |item| switch (item.node.Metadata.node) {
                        .List => |lst| {
                            const mt = try self.expectNode(.Keyword, &lst.body.items[0]);
                            if (mem.eql(u8, mt, "method")) {
                                try self.validateListLength(lst.body.items, 2);
                                is_method = TypeInfo{ .Unresolved = .{
                                    .ident = try self.expectNode(.Keyword, &lst.body.items[1]),
                                    .srcloc = lst.body.items[1].location,
                                } };
                            } else {
                                return self.program.perr(error.InvalidMetadata, lst.body.items[0].location);
                            }
                        },
                        .Keyword => |kwd| {
                            if (mem.eql(u8, kwd, "private")) {
                                is_private = true;
                            } else if (mem.eql(u8, kwd, "inline")) {
                                is_inline = .Always;
                            } else if (mem.eql(u8, kwd, "no-inline")) {
                                is_inline = .Never;
                            } else {
                                return self.program.perr(error.InvalidMetadata, item.location);
                            }
                        },
                        else => {
                            return self.program.perr(error.InvalidMetadata, item.location);
                        },
                    };

                    var arity: ?BlockAnalysis = null;
                    if (ast.len == 4)
                        arity = try self.parseArity(&ast[2]);

                    const scope = Scope.create(p_scope);
                    const body_ind: usize = if (ast.len == 4) @as(usize, 3) else 2;
                    const ast_body = try self.expectNode(.Quote, &ast[body_ind]);
                    const body = try self.parseStatements(ast_body.items, scope);

                    break :b ASTNode{ .node = .{ .Decl = .{
                        .name = name,
                        .variations = ASTNodePtrList.init(self.alloc),
                        .arity = arity,
                        .body = body,
                        .scope = scope,
                        .is_method = is_method,
                        .is_private = is_private,
                        .is_inline = is_inline,
                    } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "test")) {
                    const name = try self.expectNode(.Keyword, &ast[1]);
                    const ast_body = try self.expectNode(.Quote, &ast[2]);
                    const body = try self.parseStatements(ast_body.items, p_scope);

                    // const new_name = try std.fmt.allocPrint(
                    //     common.gpa.allocator(),
                    //     "test_{}_{s}",
                    //     .{ self.program.rng.random().int(u16), name },
                    // );

                    break :b ASTNode{ .node = .{ .Decl = .{
                        .name = name,
                        .body = body,
                        .is_test = true,
                        .variations = undefined,
                        .scope = Scope.create(p_scope),
                    } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "var")) {
                    try self.validateListLength(ast, 3);
                    const name = try self.expectNode(.Keyword, &ast[1]);
                    const ltyp = try self.parseType(&ast[2]);

                    break :b ASTNode{
                        .node = .{ .VDecl = .{
                            .name = name,
                            .utyp = ltyp,
                            .lind = 0xFFFF,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "wild")) {
                    try self.validateListLength(ast, 3);

                    const arity = try self.parseArity(&ast[1]);
                    const ast_body = try self.expectNode(.Quote, &ast[2]);
                    const block = try self.parseStatements(ast_body.items, p_scope);

                    break :b ASTNode{
                        .node = .{ .Wild = .{ .arity = arity, .body = block } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "r")) {
                    try self.validateListLength(ast, 2);

                    const ast_body = switch (ast[1].node) {
                        .Quote => ast[1].node.Quote.items,
                        else => ast[1..],
                    };
                    const block = try self.parseStatements(ast_body, p_scope);

                    break :b ASTNode{
                        .node = .{ .RBlock = .{ .body = block } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "split")) {
                    break :b ASTNode{
                        .node = .{ .Builtin = .{ .type = .{ .SplitCast = .{
                            .original1 = try self.parseType(&ast[1]),
                            .original2 = try self.parseType(&ast[2]),
                        } } } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "as")) {
                    const from = StackBuffer(TypeInfo, 3).new();
                    const orig = StackBuffer(TypeInfo, 3).new();
                    const resv = StackBuffer(TypeInfo, 3).new();
                    for (ast[1..]) |node| {
                        orig.append(try self.parseType(&node)) catch unreachable;
                        resv.append(.Any) catch unreachable;
                        from.append(.Any) catch unreachable;
                    }
                    break :b ASTNode{
                        .node = .{ .Cast = .{
                            .from = from,
                            .original = orig,
                            .resolved = resv,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "use") or mem.eql(u8, k, "use*")) {
                    try self.validateListLength(ast, 2);
                    const name = try self.expectNode(.Keyword, &ast[1]);
                    const is_defiling = mem.eql(u8, k, "use*");
                    self.stuff_to_import = true;
                    break :b ASTNode{
                        .node = .{ .Import = .{
                            .name = name,
                            .path = "<unresolved>",
                            .scope = Scope.create(null),
                            .body = undefined,
                            .is_defiling = is_defiling,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "return")) {
                    try self.validateListLength(ast, 1);
                    break :b ASTNode{ .node = .Return, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "here")) {
                    break :b ASTNode{ .node = .Here, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "of")) {
                    if (ast[1].node == .MethodCall)
                        @panic("TODO: of() w/ method calls");
                    const name = try self.expectNode(.Keyword, &ast[1]);
                    var args = StackBuffer(TypeInfo, 2).init(null);
                    for (ast[2..]) |item| {
                        args.append(try self.parseType(&item)) catch unreachable;
                    }
                    break :b ASTNode{ .node = .{ .Call = .{
                        .name = name,
                        .args = args,
                    } }, .srcloc = ast[1].location };
                } else if (mem.eql(u8, k, "make")) {
                    try self.validateListLength(ast, 2);
                    const typ = try self.parseType(&ast[1]);
                    break :b ASTNode{ .node = .{ .Builtin = .{ .type = .{ .Make = .{
                        .original = typ,
                        .resolved = .Any,
                    } } } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "sizeof")) {
                    try self.validateListLength(ast, 2);
                    const typ = try self.parseType(&ast[1]);
                    break :b ASTNode{ .node = .{ .Builtin = .{ .type = .{ .SizeOf = .{
                        .original = typ,
                        .resolved = .Any,
                    } } } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "should")) {
                    const t = try self.expectNode(.Keyword, &ast[1]);
                    var b: common.Breakpoint.Type = undefined;

                    if (mem.eql(u8, t, "eq")) {
                        if (ast.len > 2) {
                            const v = try self.parseValue(&ast[2]);
                            b = .{ .TosShouldEq = v };
                        } else {
                            b = .{ .TosShouldEqSos = .Any };
                        }
                    } else if (mem.eql(u8, t, "neq")) {
                        if (ast.len > 2) {
                            const v = try self.parseValue(&ast[2]);
                            b = .{ .TosShouldNeq = v };
                        } else {
                            b = .{ .TosShouldNeqSos = .Any };
                        }
                    } else if (mem.eql(u8, t, "stdout-eq")) {
                        const v = try self.parseValue(&ast[2]);
                        const str = self.program.statics.items[v.typ.StaticPtr];
                        b = .{ .StdoutShouldEq = str.default.String };
                    } else {
                        @panic("Invalid breakpoint type");
                    }

                    break :b ASTNode{ .node = .{ .Breakpoint = .{
                        .type = b,
                    } }, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "debug")) {
                    break :b ASTNode{ .node = .Debug, .srcloc = ast[0].location };
                } else if (mem.eql(u8, k, "until") or mem.eql(u8, k, "while")) {
                    try self.validateListLength(ast, 3);

                    const ast_cond = try self.expectNode(.Quote, &ast[1]);
                    const cond = try self.parseStatements(ast_cond.items, p_scope);

                    const ast_body = try self.expectNode(.Quote, &ast[2]);
                    const body = try self.parseStatements(ast_body.items, p_scope);

                    break :b ASTNode{
                        .node = .{ .Loop = .{
                            .loop = if (mem.eql(u8, k, "while"))
                                .{ .While = .{ .cond = cond, .cond_prep = .Unchecked } }
                            else
                                .{ .Until = .{ .cond = cond, .cond_prep = .Unchecked } },
                            .body = body,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "when")) {
                    const yup_n = try self.expectNode(.Quote, &ast[1]);
                    const yup = try self.parseStatements(yup_n.items, p_scope);
                    const nah = if (ast.len > 2) ifb: {
                        const nah_n = try self.expectNode(.Quote, &ast[2]);
                        break :ifb try self.parseStatements(nah_n.items, p_scope);
                    } else null;
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
                        const q = try self.expectNode(.Quote, node);
                        try all_branches.append(try self.parseStatements(q.items, p_scope));
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
                    try self.validateListLength(ast, 3);

                    const asm_flags = try self.parseValue(&ast[1]);
                    if (asm_flags.typ != .StaticPtr and
                        self.program.statics.items[asm_flags.typ.StaticPtr].default != .String)
                        return error.ExpectedString;

                    var asm_stack: usize = WK_STACK;
                    var asm_keep = false;
                    var asm_short = false;
                    var asm_generic = false;
                    const str = self.program.statics.items[asm_flags.typ.StaticPtr].default.String;
                    for (str.items) |char| switch (char) {
                        'k' => asm_keep = true,
                        'r' => asm_stack = RT_STACK,
                        's' => asm_short = true,
                        'g' => asm_generic = true,
                        else => return error.InvalidAsmFlag,
                    };

                    const asm_op_kwd = try self.parseValue(&ast[2]);
                    if (asm_op_kwd.typ != .AmbigEnumLit)
                        return error.ExpectedEnumLit;
                    const asm_val = try self.lowerEnumValue(asm_op_kwd.val.AmbigEnumLit, ast[2].location);
                    const asm_typ = self.program.types.items[asm_val.Value.val.typ.EnumLit];
                    const asm_name = asm_typ.def.Enum.fields.items[asm_val.Value.val.val.EnumLit].name;
                    var asm_op_e: ?Op.Tag = null;
                    // meta.stringToEnum causes stack corruption in certain case
                    // I really should file an issue about this...
                    inline for (@typeInfo(Op.Tag).Enum.fields) |enumField| {
                        if (mem.eql(u8, asm_name, enumField.name)) {
                            asm_op_e = @field(Op.Tag, enumField.name);
                        }
                    }
                    const asm_op = Op.fromTag(
                        asm_op_e orelse return error.InvalidAsmOp,
                    ) catch return error.InvalidAsmOp;
                    break :b ASTNode{
                        .node = .{ .Asm = .{
                            .stack = asm_stack,
                            .short = asm_short,
                            .generic = asm_generic,
                            .keep = asm_keep,
                            .op = asm_op,
                        } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "device") or
                    mem.eql(u8, k, "typealias") or
                    mem.eql(u8, k, "struct"))
                {
                    break :b try self.parseTypeDecl(ast, metadata);
                } else {
                    std.log.info("Unknown keyword: {s}", .{k});
                    break :b error.UnknownKeyword;
                }
            },
            .List => |l| try self.parseList(l.body.items, l.metadata.items, p_scope),
            else => try self.parseStatement(&ast[0], p_scope),
        };
    }

    // Extract definitions
    pub fn extractDefs(parser_: *Parser) ErrorSet!void {
        try parser_.program.walkNodes(null, parser_.program.ast, {}, struct {
            pub fn f(node: *ASTNode, parent: ?*ASTNode, self: *Program, _: void) ErrorSet!void {
                switch (node.node) {
                    .Decl => |d| {
                        // const pname: []const u8 = if (parent) |p| switch (p.node) {
                        //     .Decl => |d| d.name,
                        //     .Import => |i| i.name,
                        //     else => unreachable,
                        // } else "<global>";
                        // std.log.info("function: {s} -> {s}", .{
                        //     node.node.Decl.name,
                        //     pname,
                        // });

                        const scope = if (parent) |p| switch (p.node) {
                            .Decl => |de| de.scope,
                            .Import => |i| i.scope,
                            else => unreachable,
                        } else self.global_scope;

                        const method_scope = if (d.is_method) |method_type|
                            if (scope.findType(method_type.Unresolved.ident, self, true)) |t|
                                self.types.items[t].scope
                            else
                                return self.aerr(
                                    error.NoSuchType,
                                    method_type.Unresolved.srcloc,
                                )
                        else
                            null;

                        try (method_scope orelse scope).defs.append(node);
                        try self.defs.append(node);
                    },
                    else => {},
                }
            }
        }.f);

        var i: usize = 0;
        while (i < parser_.program.defs.items.len) {
            const item = parser_.program.defs.items[i];
            const contains = for (parser_.program.defs.items[0..i]) |otheritem| {
                if (otheritem == item) break true;
            } else false;
            if (contains) {
                _ = parser_.program.defs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn lowerEnumValue(self: *Parser, lit: lexer.Node.EnumLit, srcloc: Srcloc) ParserError!ASTNode.Type {
        if (lit.of == null)
            return error.MissingEnumType;
        for (self.program.types.items, 0..) |t, i| {
            if (mem.eql(u8, t.name, lit.of.?)) switch (t.def) {
                .Enum => |edef| {
                    for (edef.fields.items, 0..) |field, field_i| {
                        if (mem.eql(u8, field.name, lit.v)) {
                            return .{ .Value = .{ .val = .{
                                .typ = .{ .EnumLit = i },
                                .val = .{ .EnumLit = field_i },
                            } } };
                        }
                    }
                    return self.program.perr(error.InvalidEnumField, srcloc);
                },
                .Device => |ddef| {
                    for (ddef.fields.items, 0..) |field, field_i| {
                        if (mem.eql(u8, field.name, lit.v)) {
                            const bit = field.type.bits(self.program).?;
                            const typ: TypeInfo = if (bit == 16) .Dev16 else .Dev8;
                            return .{ .Value = .{ .val = .{ .typ = typ, .val = .{
                                .Device = .{ .dev_i = i, .field = field_i },
                            } } } };
                        }
                    }
                    return self.program.perr(error.InvalidEnumField, srcloc);
                },
                else => return error.NotAnEnumOrDevice,
            };
        }
        return self.program.perr(error.NoSuchType, srcloc);
    }

    pub fn extractTypes(parser_: *Parser) ErrorSet!void {
        // Add typedefs
        try parser_.program.walkNodes(null, parser_.program.ast, parser_, struct {
            pub fn _f(node: *ASTNode, parent: ?*ASTNode, self: *Program, parser: *Parser) ErrorSet!void {
                if (node.node != .TypeDef) return;

                const scope = if (parent) |p| switch (p.node) {
                    .Decl => |d| d.scope,
                    .Import => |i| i.scope,
                    else => unreachable,
                } else self.global_scope;

                // FIXME: check for name collisions
                switch (node.node.TypeDef.def) {
                    .Alias => |aliasdef| {
                        self.types.append(UserType{
                            .node = node,
                            .name = node.node.TypeDef.name,
                            .scope = Scope.create(scope),
                            .is_private = node.node.TypeDef.is_private,
                            .def = .{ .Alias = .{
                                .val = try aliasdef.val.resolveTypeRef(scope, null, self),
                            } },
                        }) catch unreachable;
                        scope.types.append(self.types.items.len - 1) catch unreachable;
                    },
                    .Struct => |strdef| {
                        self.types.append(UserType{
                            .node = node,
                            .name = node.node.TypeDef.name,
                            .scope = Scope.create(scope),
                            .is_private = node.node.TypeDef.is_private,
                            .def = .{ .Struct = .{
                                .args = strdef.args,
                                .fields = UserType.StructField.AList.init(parser.alloc),
                            } },
                        }) catch unreachable;
                        scope.types.append(self.types.items.len - 1) catch unreachable;
                        const fields = &self.types.items[self.types.items.len - 1].def.Struct.fields;

                        var offset: u16 = 0;
                        for (strdef.fields.items, 0..) |field, i| {
                            if (strdef.args == null) {
                                const f = try field.type.resolveTypeRef(scope, null, self);
                                const size = f.size(self) orelse b: {
                                    if (f == .Array and f.Array.count == null and
                                        i == strdef.fields.items.len - 1)
                                        break :b @as(u16, 0); // Last field, no issues
                                    return self.perr(error.InvalidFieldType, field.srcloc);
                                };

                                common.UserType.checkStructField(f, i == strdef.fields.items.len - 1);

                                fields.append(.{
                                    .name = field.name,
                                    .type = f,
                                    .offset = offset,
                                }) catch unreachable;
                                offset += size;
                            } else {
                                fields.append(
                                    .{ .name = field.name, .type = field.type },
                                ) catch unreachable;
                            }
                        }
                    },
                    .Device => |devdef| {
                        var fields = UserType.DeviceField.AList.init(parser.alloc);
                        for (devdef.fields.items) |field| {
                            fields.append(.{ .name = field.name, .type = field.type }) catch unreachable;
                        }
                        self.types.append(UserType{
                            .node = node,
                            .name = node.node.TypeDef.name,
                            .scope = Scope.create(scope),
                            .is_private = node.node.TypeDef.is_private,
                            .def = .{ .Device = .{ .start = devdef.start, .fields = fields } },
                        }) catch unreachable;
                        scope.types.append(self.types.items.len - 1) catch unreachable;
                    },
                }
            }
        }._f);
    }

    pub fn postProcess(parser_: *Parser) ErrorSet!void {
        // Earlier we couldn't know what type an Enum literal belonged to. At this
        // stage we find and set that information.
        //
        // Also check calls to determine what type they are.
        try parser_.program.walkNodes(null, parser_.program.ast, parser_, struct {
            pub fn f(node: *ASTNode, parent: ?*ASTNode, self: *Program, parser: *Parser) ErrorSet!void {
                switch (node.node) {
                    .Import => |i| if (i.is_dupe) return error._Continue,
                    .Value => |v| switch (v.val.typ) {
                        .AmbigEnumLit => node.node = try parser.lowerEnumValue(v.val.val.AmbigEnumLit, node.srcloc),
                        else => {},
                    },
                    .VDecl => |*vd| {
                        parent.?.node.Decl.locals.append(.{
                            .name = vd.name,
                            .rtyp = vd.utyp,
                            .ind = 0xFFFF,
                        }) catch unreachable;
                        vd.lind = parent.?.node.Decl.locals.len - 1;
                    },
                    .VRef => |*v| {
                        v.lind = for (parent.?.node.Decl.locals.constSlice(), 0..) |local, i| {
                            if (mem.eql(u8, v.name, local.name))
                                break i;
                        } else return self.perr(error.UnknownLocal, node.srcloc);
                    },
                    .VDeref => |*v| {
                        v.lind = for (parent.?.node.Decl.locals.constSlice(), 0..) |local, i| {
                            if (mem.eql(u8, v.name, local.name))
                                break i;
                        } else return self.perr(error.UnknownLocal, node.srcloc);
                    },
                    else => {},
                }
            }
        }.f);
    }

    // Not really part of parsing
    pub fn importModules(parser_: *Parser) ErrorSet!void {
        parser_.stuff_to_import = false;

        try parser_.program.walkNodes(null, parser_.program.ast, parser_, struct {
            pub fn f(node: *ASTNode, parent: ?*ASTNode, self: *Program, _: *Parser) ErrorSet!void {
                if (node.node == .Import) {
                    self.imports.append(node) catch unreachable;
                    if (parent) |p| {
                        switch (p.node) {
                            .Decl => |d| d.scope.imports.append(node) catch unreachable,
                            .Import => |i| i.scope.imports.append(node) catch unreachable,
                            else => {},
                        }
                    } else {
                        self.global_scope.imports.append(node) catch unreachable;
                    }
                }
            }
        }.f);

        const self = parser_.program;

        for (self.imports.items) |*importptr| {
            const import = &importptr.*.node.Import;
            if (!mem.eql(u8, import.path, "<unresolved>"))
                continue;

            var path: []const u8 = "";

            const PATHS = [_][]const u8{ "{s}.bur", "std/{s}.bur", "{s}/prelude.bur" };

            inline for (PATHS) |possible_path_fmt| {
                const possible_path = std.fmt.allocPrint(
                    parser_.alloc,
                    possible_path_fmt,
                    .{import.name},
                ) catch unreachable;
                if (std.fs.cwd().statFile(possible_path)) |_| {
                    path = possible_path;
                } else |_| {
                    parser_.alloc.free(possible_path);
                }
            }

            if (path.len == 0) return error.InvalidImport;

            const already_imported: ?*ASTNode = for (self.imports.items) |imp| {
                if (mem.eql(u8, imp.node.Import.path, path)) break imp;
            } else null;

            if (already_imported) |nodeptr| {
                assert(importptr.* != nodeptr);
                import.body = nodeptr.node.Import.body;
                import.is_dupe = true;
                continue;
            }

            import.path = path;
            import.body = ASTNodeList.init(parser_.alloc);

            const file = std.fs.cwd().openFile(path, .{}) catch unreachable;
            defer file.close();

            const size = try file.getEndPos();
            const buf = try parser_.alloc.alloc(u8, size);
            defer parser_.alloc.free(buf);
            _ = try file.readAll(buf);

            var lex = lexer.Lexer.init(buf, path, parser_.alloc);
            const lexed = try lex.lexList(.Root);
            defer lex.deinit();

            for (lexed.items) |*node| try import.body.append(switch (node.node) {
                .List => |l| try parser_.parseList(l.body.items, l.metadata.items, import.scope),
                else => try parser_.parseStatement(node, import.scope),
            });
        }

        if (parser_.stuff_to_import)
            try parser_.importModules();
    }

    pub fn setupMainFunc(self: *Parser) ParserError!void {
        var iter2 = self.program.ast.iterator();
        while (iter2.next()) |ast_item|
            switch (ast_item.node) {
                .Import, .Decl, .VDecl, .TypeDef => {},
                else => return error.NakedStatements,
            };

        if (self.is_testing) return;

        const main_func = self.program.global_scope.findDeclAny("main") orelse
            return error.NoMainFunction;

        try main_func.node.Decl.body.append(ASTNode{ .node = .{
            .Asm = .{ .stack = WK_STACK, .op = .Ohalt },
        }, .srcloc = .{} });

        try self.program.ast.insertAtInd(0, ASTNode{ .node = .{ .Call = .{
            .name = "main",
            .node = main_func,
            .variant = 0,
            .goto = true,
        } }, .srcloc = .{} });
    }

    pub fn parse(self: *Parser, lexed: *const lexer.NodeList) ErrorSet!void {
        for (lexed.items) |*node| try self.program.ast.append(switch (node.node) {
            .List => |l| try self.parseList(l.body.items, l.metadata.items, self.program.global_scope),
            else => try self.parseStatement(node, self.program.global_scope),
        });

        try self.importModules();
        try self.extractTypes();
        try self.extractDefs();
        try self.setupMainFunc();
        try self.postProcess();
    }
};
