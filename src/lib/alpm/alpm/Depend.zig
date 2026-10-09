ptr: *c.alpm_depend_t,

/// Gets the name of the dependency.
/// The returned slice is owned by the Depend's parent Package.
pub fn getName(self: *const Depend) []const u8 {
    return std.mem.sliceTo(self.ptr.name, 0);
}

/// Gets the required version of the dependency, if any.
/// The returned slice is owned by the Depend's parent Package.
pub fn getVersion(self: *const Depend) ?[]const u8 {
    if (self.ptr.version == null) return null;
    return std.mem.sliceTo(self.ptr.version, 0);
}

/// Computes the full dependency string (e.g., "glibc>=2.35").
/// The returned slice is allocated using `allocator` and must be freed by the caller.
pub fn computeString(self: *const Depend, allocator: std.mem.Allocator) ![]u8 {
    const c_str = c.alpm_dep_compute_string(self.ptr);
    if (c_str == null) return error.AllocFailed;
    defer c.free(c_str);
    return allocator.dupe(u8, std.mem.sliceTo(c_str, 0));
}

pub const List = alpm.ListWrapper(Depend, *c.alpm_depend_t);

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const Database = alpm.Database;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const Depend = @This();
