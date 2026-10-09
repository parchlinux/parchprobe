ptr: *c.alpm_group_t,

/// Gets the name of the group. The slice is owned by the parent Database.
pub fn getName(self: *const Group) []const u8 {
    return std.mem.sliceTo(self.ptr.name, 0);
}

/// Gets the list of packages in this group.
/// The returned List and its Packages are owned by the parent Database.
pub fn getPackages(self: *const Group) Package.List {
    return .fromList(self.ptr.packages);
}

pub const List = alpm.ListWrapper(Group, *c.alpm_group_t);

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const Database = alpm.Database;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const Group = @This();
