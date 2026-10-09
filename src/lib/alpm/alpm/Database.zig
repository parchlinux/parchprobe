ptr: *c.alpm_db_t,

pub const Usage = packed struct(c_int) {
    sync: bool = false,
    search: bool = false,
    install: bool = false,
    upgrade: bool = false,
    _padding: u28 = 0,

    pub var all: Usage = .{
        .sync = true,
        .search = true,
        .install = true,
        .upgrade = true,
    };
};

/// Unregisters this database. Cannot be called during an active transaction.
pub fn unregister(self: *Database) !void {
    if (c.alpm_db_unregister(self.ptr) != 0) {
        @branchHint(.unlikely);
        const handle = c.alpm_db_get_handle(self.ptr);
        return alpm.errnoToError(c.alpm_errno(handle));
    }
}

/// Gets the name of the database.
/// The returned slice is owned by the Database and is valid until it is unregistered.
pub fn getName(self: *const Database) []const u8 {
    return std.mem.sliceTo(c.alpm_db_get_name(self.ptr), 0);
}

/// Gets the package cache for this database (a list of all packages).
/// The returned List and its Packages are owned by the Database.
pub fn getPackageCache(self: *const Database) Package.List {
    return .fromList(c.alpm_db_get_pkgcache(self.ptr));
}

/// Finds and retrieves a package by name from this database.
/// The returned Package is owned by the Database.
pub fn getPackage(self: *const Database, name: [*:0]const u8) ?Package {
    const pkg_ptr = c.alpm_db_get_pkg(self.ptr, name);
    if (pkg_ptr == null) return null;
    return .{ .ptr = pkg_ptr.? };
}

/// Adds a download server URL to the database.
pub fn addServer(self: *Database, url: [*:0]const u8) !void {
    if (c.alpm_db_add_server(self.ptr, url) != 0) {
        @branchHint(.unlikely);
        const handle = c.alpm_db_get_handle(self.ptr);
        return alpm.errnoToError(c.alpm_errno(handle));
    }
}

/// Gets the list of server URLs for this database.
/// The returned List and its string slices are owned by the Database.
pub fn getServers(self: *const Database) alpm.StringList {
    return .{ .list = c.alpm_db_get_servers(self.ptr) };
}

/// Sets the usage flags for this database.
pub fn setUsage(self: *Database, usage: Usage) !void {
    if (c.alpm_db_set_usage(self.ptr, @bitCast(usage)) != 0) {
        @branchHint(.unlikely);
        const handle = c.alpm_db_get_handle(self.ptr);
        return alpm.errnoToError(c.alpm_errno(handle));
    }
}

/// Gets a group by name from this database.
/// The returned Group is owned by the Database.
pub fn getGroup(self: *const Database, name: [*:0]const u8) ?Group {
    const group_ptr = c.alpm_db_get_group(self.ptr, name);
    if (group_ptr == null) return null;
    return .{ .ptr = group_ptr.? };
}

/// Gets the group cache for this database (a list of all groups).
/// The returned List and its Groups are owned by the Database.
pub fn getGroupCache(self: *const Database) Group.List {
    return .fromList(c.alpm_db_get_groupcache(self.ptr));
}

pub const List = alpm.ListWrapper(Database, *c.alpm_db_t);

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const Group = alpm.Group;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const Database = @This();
