const std = @import("std");
const Allocator = std.mem.Allocator;
const Map = std.AutoHashMap;
const List = std.ArrayList;

const Builtins = @import("../builtins.zig").Builtins;
const Indent = @import("../indent.zig").Indent;
const interner = @import("../interner.zig");
const Interned = interner.Interned;
const parser = @import("../parser.zig");
const substitution = @import("../substitution.zig");
const MonoType = substitution.MonoType;
const Substitution = substitution.Substitution;
const TypeVar = substitution.TypeVar;
const Constraints = @import("../constraints.zig").Constraints;
const CompileErrors = @import("../compile_errors.zig").CompileErrors;
pub const Span = parser.types.Span;

pub const WorkQueue = List(Interned);

pub const Binding = struct {
    type: MonoType,
    global: bool,
    mutable: bool,
};

pub const Scope = Map(Interned, Binding);

pub const Scopes = struct {
    allocator: Allocator,
    base: Scope,
    scopes: List(Scope),
    work_queue: *WorkQueue,
    compile_errors: *CompileErrors,

    pub fn init(allocator: Allocator, base: Scope, work_queue: *WorkQueue, compile_errors: *CompileErrors) !Scopes {
        var scopes = List(Scope).init(allocator);
        try scopes.append(Scope.init(allocator));
        return .{
            .allocator = allocator,
            .work_queue = work_queue,
            .scopes = scopes,
            .base = base,
            .compile_errors = compile_errors,
        };
    }

    pub fn push(self: *Scopes) !void {
        try self.scopes.append(Scope.init(self.allocator));
    }

    pub fn pop(self: *Scopes) void {
        _ = self.scopes.pop();
    }

    pub fn put(self: *Scopes, name: Interned, binding: Binding) !void {
        try self.scopes.items[self.scopes.items.len - 1].put(name, binding);
    }

    pub fn find(self: Scopes, symbol: parser.types.Symbol) !Binding {
        var reverse_iterator = std.mem.reverseIterator(self.scopes.items);
        while (reverse_iterator.next()) |scope| {
            if (scope.get(symbol.value)) |binding| return binding;
        }
        if (self.base.get(symbol.value)) |binding| {
            try self.work_queue.append(symbol.value);
            return binding;
        }
        var in_scope = List(Interned).init(self.allocator);
        var base_iterator = self.base.keyIterator();
        while (base_iterator.next()) |key| try in_scope.append(key.*);
        for (self.scopes.items) |scope| {
            var scope_iterator = scope.keyIterator();
            while (scope_iterator.next()) |key| try in_scope.append(key.*);
        }
        try self.compile_errors.errors.append(.{
            .undefined_variable = .{
                .symbol = symbol.value,
                .span = symbol.span,
                .in_scope = try in_scope.toOwnedSlice(),
            },
        });
        return error.CompileError;
    }
};

pub const Int = struct {
    value: Interned,
    span: Span,
    type: MonoType,
};

pub const Float = struct {
    value: Interned,
    span: Span,
    type: MonoType,
};

pub const Symbol = struct {
    value: Interned,
    span: Span,
    global: bool,
    mutable: bool,
    type: MonoType,
};

pub const Bool = struct {
    value: bool,
    span: Span,
    type: MonoType,
};

pub const String = struct {
    value: Interned,
    span: Span,
    type: MonoType,
};

pub const Define = struct {
    name: Symbol,
    value: *Expression,
    span: Span,
    mutable: bool,
    type: MonoType,
};

pub const AddAssign = struct {
    name: Symbol,
    value: *Expression,
    span: Span,
    type: MonoType,
};

pub const Block = struct {
    expressions: []Expression,
    span: Span,
    type: MonoType,
};

pub const Function = struct {
    parameters: []Symbol,
    return_type: MonoType,
    body: Block,
    span: Span,
    type: MonoType,
};

pub const BinaryOp = struct {
    kind: parser.types.BinaryOpKind,
    left: *Expression,
    right: *Expression,
    span: Span,
    type: MonoType,
};

pub const Arm = struct {
    condition: Expression,
    then: Block,
};

pub const Branch = struct {
    arms: []Arm,
    else_: Block,
    span: Span,
    type: MonoType,
};

pub const Call = struct {
    function: *Expression,
    arguments: []Expression,
    span: Span,
    type: MonoType,
};

pub const Intrinsic = struct {
    function: Interned,
    arguments: []Expression,
    span: Span,
    type: MonoType,
};

pub const Group = struct {
    expressions: []Expression,
    span: Span,
    type: MonoType,
};

pub const ForeignImport = struct {
    module: Interned,
    name: Interned,
    span: Span,
    type: MonoType,
};

pub const ForeignExport = struct {
    name: Interned,
    value: *Expression,
    span: Span,
    type: MonoType,
};

pub const Convert = struct {
    value: *Expression,
    span: Span,
    type: MonoType,
};

pub const Undefined = struct {
    span: Span,
    type: MonoType,
};

pub const Expression = union(enum) {
    int: Int,
    float: Float,
    symbol: Symbol,
    bool: Bool,
    string: String,
    define: Define,
    add_assign: AddAssign,
    function: Function,
    binary_op: BinaryOp,
    group: Group,
    block: Block,
    branch: Branch,
    call: Call,
    intrinsic: Intrinsic,
    foreign_import: ForeignImport,
    foreign_export: ForeignExport,
    convert: Convert,
    undefined: Undefined,
};

pub const Untyped = Map(Interned, parser.types.Expression);
pub const Typed = Map(Interned, Expression);

pub const Module = struct {
    allocator: Allocator,
    constraints: *Constraints,
    builtins: Builtins,
    order: []const Interned,
    untyped: Untyped,
    typed: Typed,
    scope: Scope,
    foreign_exports: []const Interned,
    compile_errors: *CompileErrors,

    pub fn init(allocator: Allocator, constraints: *Constraints, builtins: Builtins, compile_errors: *CompileErrors, ast: parser.types.Module) !Module {
        var order = List(Interned).init(allocator);
        var untyped = Untyped.init(allocator);
        var typed = Typed.init(allocator);
        var scope = Scope.init(allocator);
        var foreign_exports = List(Interned).init(allocator);
        for (ast.expressions) |top_level| {
            switch (top_level) {
                .define => |d| {
                    const name = d.name.value;
                    try order.append(name);
                    try untyped.putNoClobber(name, top_level);
                    const monotype = try topLevelType(allocator, builtins, d);
                    try scope.put(name, Binding{
                        .type = monotype,
                        .global = true,
                        .mutable = false,
                    });
                },
                .call => |c| {
                    switch (c.function.*) {
                        .symbol => |sym| {
                            if (sym.value.eql(builtins.foreign_export)) {
                                if (c.arguments.len != 2) std.debug.panic("\nInvalid foreign export call {}", .{c});
                                switch (c.arguments[0]) {
                                    .string => |str| {
                                        try order.append(str.value);
                                        try untyped.putNoClobber(str.value, top_level);
                                        try foreign_exports.append(str.value);
                                    },
                                    else => |k| std.debug.panic("\nInvalid foreign export call {}", .{k}),
                                }
                            } else {
                                std.debug.panic("\nInvalid top level call to {}", .{sym});
                            }
                        },
                        else => |k| std.debug.panic("\nInvalid top level call {}", .{k}),
                    }
                },
                else => |k| std.debug.panic("\nInvalid top level expression {}", .{k}),
            }
        }
        return Module{
            .allocator = allocator,
            .constraints = constraints,
            .builtins = builtins,
            .order = try order.toOwnedSlice(),
            .untyped = untyped,
            .typed = typed,
            .scope = scope,
            .foreign_exports = try foreign_exports.toOwnedSlice(),
            .compile_errors = compile_errors,
        };
    }
};

fn topLevelFunction(allocator: Allocator, builtins: Builtins, f: parser.types.Function) !MonoType {
    const len = f.parameters.len;
    const function_type = try allocator.alloc(MonoType, len + 1);
    for (f.parameters, function_type[0..len]) |p, *t|
        t.* = try expressionToMonoType(allocator, builtins, p.type);
    function_type[len] = try expressionToMonoType(allocator, builtins, f.return_type.*);
    return MonoType{ .function = function_type };
}

fn topLevelCall(allocator: Allocator, builtins: Builtins, c: parser.types.Call) !MonoType {
    switch (c.function.*) {
        .symbol => |s| {
            if (s.value.eql(builtins.foreign_import)) {
                if (c.arguments.len != 3) std.debug.panic("foreign_import takes 3 arguments", .{});
                return try expressionToMonoType(allocator, builtins, c.arguments[2]);
            }
        },
        else => |k| std.debug.panic("\nInvalid top level call function {}", .{k}),
    }
    std.debug.panic("\nInvalid top level call {}", .{c.function});
}

fn topLevelInt(allocator: Allocator, builtins: Builtins, d: parser.types.Define) !MonoType {
    if (d.type) |t| {
        return try expressionToMonoType(allocator, builtins, t.*);
    }
    std.debug.panic("\nInvalid top level int {}", .{d});
}

fn topLevelType(allocator: Allocator, builtins: Builtins, d: parser.types.Define) !MonoType {
    return switch (d.value.*) {
        .function => |f| try topLevelFunction(allocator, builtins, f),
        .call => |c| try topLevelCall(allocator, builtins, c),
        .int => try topLevelInt(allocator, builtins, d),
        else => |k| std.debug.panic("\nInvalid top level value {}", .{k}),
    };
}

pub fn expressionToMonoType(allocator: Allocator, builtins: Builtins, e: parser.types.Expression) !MonoType {
    switch (e) {
        .symbol => |s| {
            if (s.value.eql(builtins.u8)) return .u8;
            if (s.value.eql(builtins.i32)) return .i32;
            if (s.value.eql(builtins.i64)) return .i64;
            if (s.value.eql(builtins.f32)) return .f32;
            if (s.value.eql(builtins.f64)) return .f64;
            if (s.value.eql(builtins.bool)) return .bool;
            if (s.value.eql(builtins.void)) return .void;
            std.debug.panic("\nCannot convert symbol {} to mono type", .{s});
        },
        .prototype => |p| {
            const len = p.parameters.len;
            const function_type = try allocator.alloc(MonoType, len + 1);
            for (p.parameters, function_type[0..len]) |param, *t|
                t.* = try expressionToMonoType(allocator, builtins, param.type);
            function_type[len] = try expressionToMonoType(allocator, builtins, p.return_type.*);
            return MonoType{ .function = function_type };
        },
        .array_of => |a| {
            if (a.size) |_| std.debug.panic("\nSize of array currently not supported", .{});
            const element_type = try allocator.create(MonoType);
            element_type.* = try expressionToMonoType(allocator, builtins, a.element_type.*);
            return MonoType{ .array = .{ .size = null, .element_type = element_type } };
        },
        else => std.debug.panic("\nCannot convert expression {} to mono type", .{e}),
    }
}
