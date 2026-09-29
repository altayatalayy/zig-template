//! The parsed form of a template: a flat list of nodes with conditions and
//! loops nested by slice. The parser produces it; the renderer consumes it.
//! It is allocated in a `Template`'s arena and borrows the source text, so the
//! `[]const u8` fields point into the original template string.

pub const Method = enum { upper, lower };
pub const CmpOp = enum { eq, ne };

/// A dotted name (`a.b.c`), optionally ending in a method call (`name.upper()`).
pub const Path = struct { segments: []const []const u8, method: ?Method = null };

pub const Operand = union(enum) {
    string: []const u8,
    path: Path,
};

pub const Condition = struct {
    negate: bool,
    kind: union(enum) {
        truthy: Operand,
        compare: struct { lhs: Operand, op: CmpOp, rhs: Operand },
    },
};

pub const Node = union(enum) {
    text: []const u8,
    output: Operand,
    branch: Branch,
    loop: Loop,

    pub const Arm = struct { cond: Condition, body: []const Node };
    pub const Branch = struct { arms: []const Arm, otherwise: []const Node };
    pub const Loop = struct {
        var_name: []const u8,
        iterable: Path,
        body: []const Node,
        empty: []const Node,
    };
};
