ptr: *c.alpm_file_t,

/// Gets the name of the file. The slice is owned by the parent Package.
pub fn getName(self: *const File) []const u8 {
    return std.mem.sliceTo(self.ptr.name, 0);
}

/// Gets the size of the file in bytes.
pub fn getSize(self: *const File) i64 {
    return self.ptr.size;
}

/// Gets the file's permissions mode.
pub fn getMode(self: *const File) u32 {
    return self.ptr.mode;
}

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const List = alpm.List;
const Database = alpm.Database;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const File = @This();
