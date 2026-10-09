ptr: *c.alpm_filelist_t,

/// Gets the number of files in the list.
pub fn count(self: *const FileList) usize {
    return self.ptr.count;
}

/// Returns the list of files as a slice. The slice and its items are owned by the parent Package.
pub fn asSlice(self: *const FileList) []const File {
    return self.ptr.files[0..self.ptr.count];
}

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const List = alpm.List;
const Database = alpm.Database;
const File = alpm.File;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const FileList = @This();
