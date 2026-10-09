ptr: *c.alpm_pkg_t,

pub const Reason = enum(c_int) {
    Explicit = c.ALPM_PKG_REASON_EXPLICIT,
    Depend = c.ALPM_PKG_REASON_DEPEND,
    Unknown = c.ALPM_PKG_REASON_UNKNOWN,
};

/// Frees a package that was loaded from a file via `Handle.loadPackage`.
/// Do not call this on packages retrieved from a database.
pub fn deinit(pkg: *Package) void {
    _ = c.alpm_pkg_free(pkg.ptr);
}

/// Gets the package name.
/// The returned slice is owned by the Package.
pub fn getName(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_name(self.ptr), 0);
}

pub fn getNameSentinel(self: *const Package) [*:0]const u8 {
    return c.alpm_pkg_get_name(self.ptr);
}

/// Gets the package version string (e.g., "1.0.0-1").
/// The returned slice is owned by the Package.
pub fn getVersion(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_version(self.ptr), 0);
}

pub fn getVersionSentinel(self: *const Package) [*:0]const u8 {
    return c.alpm_pkg_get_version(self.ptr);
}

/// Gets the package description.
/// The returned slice is owned by the Package.
pub fn getDescription(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_desc(self.ptr), 0);
}

/// Gets the package architecture.
/// The returned slice is owned by the Package.
pub fn getArch(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_arch(self.ptr), 0);
}

/// Gets the total size of files installed by the package.
pub fn getInstalledSize(self: *const Package) i64 {
    return c.alpm_pkg_get_isize(self.ptr);
}

/// Gets the database this package belongs to. Returns null for file-based packages.
/// The returned Database is owned by the Handle.
pub fn getDb(self: *const Package) ?Database {
    const db_ptr = c.alpm_pkg_get_db(self.ptr);
    if (db_ptr == null) return null;
    return .{ .ptr = db_ptr.? };
}

/// Gets the list of package dependencies.
/// The returned List and its Depends are owned by the Package.
pub fn getDepends(self: *const Package) Depend.List {
    return .fromList(c.alpm_pkg_get_depends(self.ptr));
}

/// Gets the list of packages that provide functionality for this package.
/// The returned List and its Depends are owned by the Package.
pub fn getProvides(self: *const Package) Depend.List {
    return .fromList(c.alpm_pkg_get_provides(self.ptr));
}

/// Checks if this package should be ignored based on IgnorePkg/IgnoreGroup settings.
pub fn shouldIgnore(self: *const Package) bool {
    const handle = c.alpm_pkg_get_handle(self.ptr);
    return c.alpm_pkg_should_ignore(handle, self.ptr) != 0;
}

/// Checks the MD5 checksum of the package file from the cache.
pub fn checkMd5Sum(self: *Package) !void {
    if (c.alpm_pkg_checkmd5sum(self.ptr) != 0) {
        @branchHint(.unlikely);
        const handle = c.alpm_pkg_get_handle(self.ptr);
        return alpm.errnoToError(c.alpm_errno(handle));
    }
}

/// Sets the installation reason for a package in the local database.
/// The package must be from the local database.
pub fn setReason(self: *Package, reason: Reason) !void {
    if (c.alpm_pkg_set_reason(self.ptr, @intFromEnum(reason)) != 0) {
        @branchHint(.unlikely);
        const handle = c.alpm_pkg_get_handle(self.ptr);
        return alpm.errnoToError(c.alpm_errno(handle));
    }
}

/// Gets the filename from which the package was loaded.
/// The returned slice is owned by the Package.
pub fn getFilename(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_filename(self.ptr), 0);
}

/// Gets the package URL.
/// The returned slice is owned by the Package.
pub fn getUrl(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_url(self.ptr), 0);
}

/// Gets the build timestamp of the package.
pub fn getBuildDate(self: *const Package) i64 {
    return c.alpm_pkg_get_builddate(self.ptr);
}

/// Gets the installation timestamp of the package.
pub fn getInstallDate(self: *const Package) i64 {
    return c.alpm_pkg_get_installdate(self.ptr);
}

/// Gets the packager's name and email.
/// The returned slice is owned by the Package.
pub fn getPackager(self: *const Package) []const u8 {
    return std.mem.sliceTo(c.alpm_pkg_get_packager(self.ptr), 0);
}

/// Gets the list of package licenses.
/// The returned List and its string slices are owned by the Package.
pub fn getLicenses(self: *const Package) alpm.StringList {
    return .{ .list = c.alpm_pkg_get_licenses(self.ptr) };
}

/// Gets the list of groups the package belongs to.
/// The returned List and its string slices are owned by the Package.
pub fn getGroups(self: *const Package) alpm.StringList {
    return .{ .list = c.alpm_pkg_get_groups(self.ptr) };
}

/// Gets the list of packages conflicting with this package.
/// The returned List and its Depends are owned by the Package.
pub fn getConflicts(self: *const Package) Depend.List {
    return .fromList(c.alpm_pkg_get_conflicts(self.ptr));
}

/// Gets the list of packages replaced by this package.
/// The returned List and its Depends are owned by the Package.
pub fn getReplaces(self: *const Package) Depend.List {
    return .fromList(c.alpm_pkg_get_replaces(self.ptr));
}

/// Gets the list of files installed by this package.
/// The returned FileList is owned by the Package.
pub fn getFiles(self: *const Package) FileList {
    return .{ .ptr = c.alpm_pkg_get_files(self.ptr).? };
}

/// Checks for a newer version of this package in the provided sync databases.
/// The returned Package is owned by its Database.
pub fn getNewVersion(self: *const Package, sync_dbs: Database.List) ?Package {
    const new_pkg_ptr = c.alpm_sync_get_new_version(self.ptr, sync_dbs.list);
    if (new_pkg_ptr == null) return null;
    return .{ .ptr = new_pkg_ptr.? };
}

pub fn compareVersions(self: Package, other: Package) std.math.Order {
    const cmp = c.alpm_pkg_vercmp(self.getVersionSentinel(), other.getVersionSentinel());
    if (cmp < 0) {
        return .lt;
    } else if (cmp == 0) {
        return .eq;
    } else {
        return .gt;
    }
}

pub const List = alpm.ListWrapper(Package, *c.alpm_pkg_t);

const c = @import("c");
const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const Group = alpm.Group;
const SigLevel = alpm.SigLevel;
const Database = alpm.Database;
const Depend = alpm.Depend;
const FileList = alpm.FileList;
const Package = @This();
