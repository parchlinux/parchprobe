const std = @import("std");

/// Sysfs abstraction layer. All hardware detection goes through this so tests
/// can run against fixture trees without root access.
pub const Sysfs = struct {
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Sysfs {
        return .{ .root = try allocator.dupe(u8, root) };
    }

    pub fn initFromEnv(allocator: std.mem.Allocator) !Sysfs {
        if (getEnvVar(allocator, "PARCHPROBE_SYSFS")) |env_root| {
            defer allocator.free(env_root);
            return init(allocator, env_root);
        }
        return init(allocator, "/sys");
    }

    pub fn deinit(self: *Sysfs, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
    }

    /// Joins the sysfs root with the given path components.
    pub fn path(self: *const Sysfs, allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        try result.appendSlice(allocator, self.root);
        for (parts) |part| {
            if (result.items.len == 0 or result.items[result.items.len - 1] != '/') {
                try result.append(allocator, '/');
            }
            try result.appendSlice(allocator, part);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn readFile(self: *const Sysfs, allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
        _ = self;
        return readFileInternal(allocator, file_path);
    }

    pub fn readDir(self: *const Sysfs, allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
        _ = self;
        return readDirInternal(allocator, dir_path);
    }

    pub fn isDir(self: *const Sysfs, check_path: []const u8) bool {
        _ = self;
        return isDirInternal(check_path);
    }
};

fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch return null;
        if (n == 0) break;
        content.appendSlice(allocator, buf[0..n]) catch return null;
    }

    const bytes = content.items;
    var i: usize = 0;
    while (i < bytes.len) {
        const start = i;
        while (i < bytes.len and bytes[i] != 0) : (i += 1) {}
        const entry = bytes[start..i];
        if (i < bytes.len and bytes[i] == 0) i += 1;

        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (std.mem.eql(u8, entry[0..eq], key)) {
                return allocator.dupe(u8, entry[eq + 1 ..]) catch null;
            }
        }
    }
    return null;
}

fn readFileInternal(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, file_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.os.linux.close(fd);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    const trimmed = std.mem.trimEnd(u8, result.items, "\r\n \t");
    return try allocator.dupe(u8, trimmed);
}

fn readDirInternal(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return error.DirNotFound;
    defer _ = std.os.linux.close(fd);

    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |name| allocator.free(name);
        result.deinit(allocator);
    }

    var buf: [4096]u8 align(@alignOf(u64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(fd, &buf, buf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadDirError,
        }
        if (rc == 0) break;

        var idx: usize = 0;
        while (idx < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[idx]);
            const next_idx = idx + entry.reclen;
            if (entry.reclen == 0 or next_idx > rc) break;
            idx = next_idx;

            const name_ptr: [*]const u8 = @ptrCast(&entry.name);
            const max_name_len = entry.reclen - @offsetOf(std.os.linux.dirent64, "name");
            const name_len = std.mem.indexOfScalar(u8, name_ptr[0..max_name_len], 0) orelse max_name_len;
            const name = name_ptr[0..name_len];

            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            try result.append(allocator, try allocator.dupe(u8, name));
        }
    }

    const items = try result.toOwnedSlice(allocator);
    std.mem.sortUnstable([]const u8, items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return items;
}

fn isDirInternal(check_path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, check_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return false;
    _ = std.os.linux.close(fd);
    return true;
}

/// Reads a file and trims trailing whitespace.
pub fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return readFileInternal(allocator, file_path);
}

/// Lists directory entries (names only, not "." or "..").
pub fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    return readDirInternal(allocator, dir_path);
}

/// Checks if a path exists and is a directory.
pub fn isDir(check_path: []const u8) bool {
    return isDirInternal(check_path);
}
