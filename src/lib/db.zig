const std = @import("std");
const Bus = @import("device.zig").Bus;
const Device = @import("device.zig").Device;
const cli = @import("../cli.zig");
const sysfs = @import("sysfs.zig");
const Sysfs = sysfs.Sysfs;
const config = @import("config.zig");
const Config = config.Config;

pub const InstalledConfig = struct {
    name: []const u8,
    bus: Bus,
    source: []const u8,
    depends: [][]const u8,
    conflicts: [][]const u8,
    kernel_depends: [][]const u8,
    kernel_conflicts: [][]const u8,
    hooks_dir: []const u8,

    pub fn deinit(self: *InstalledConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
        for (self.depends) |s| allocator.free(s);
        allocator.free(self.depends);
        for (self.conflicts) |s| allocator.free(s);
        allocator.free(self.conflicts);
        for (self.kernel_depends) |s| allocator.free(s);
        allocator.free(self.kernel_depends);
        for (self.kernel_conflicts) |s| allocator.free(s);
        allocator.free(self.kernel_conflicts);
        allocator.free(self.hooks_dir);
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

/// Returns the system database root path (default: "/usr/lib/parchprobe/db").
pub fn getDbRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (getEnvVar(allocator, "PARCHPROBE_DB")) |val| {
        return val;
    }
    return allocator.dupe(u8, "/usr/lib/parchprobe/db");
}

/// Returns the installed state file path (default: "/var/lib/parchprobe/state.toml").
pub fn getStateFilePath(allocator: std.mem.Allocator) ![]const u8 {
    if (getEnvVar(allocator, "PARCHPROBE_STATE")) |val| {
        return val;
    }
    if (getEnvVar(allocator, "PARCHPROBE_LOCAL")) |val| {
        defer allocator.free(val);
        return std.fmt.allocPrint(allocator, "{s}/state.toml", .{val});
    }
    return allocator.dupe(u8, "/var/lib/parchprobe/state.toml");
}

/// Recursively discovers all PROBECONFIG files under `db_root` for the requested bus(es).
pub fn discoverConfigs(
    allocator: std.mem.Allocator,
    sysfs_inst: *const Sysfs,
    db_root: []const u8,
    bus_filter: cli.BusFilter,
) ![]Config {
    var result = std.ArrayList(Config).empty;
    errdefer {
        for (result.items) |*cfg| cfg.deinit(allocator);
        result.deinit(allocator);
    }

    if (bus_filter == .both or bus_filter == .pci) {
        const pci_dir = try std.fmt.allocPrint(allocator, "{s}/pci", .{db_root});
        defer allocator.free(pci_dir);
        if (sysfs.isDir(pci_dir)) {
            try scanDirRecursive(allocator, sysfs_inst, pci_dir, .pci, &result);
        }
    }

    if (bus_filter == .both or bus_filter == .usb) {
        const usb_dir = try std.fmt.allocPrint(allocator, "{s}/usb", .{db_root});
        defer allocator.free(usb_dir);
        if (sysfs.isDir(usb_dir)) {
            try scanDirRecursive(allocator, sysfs_inst, usb_dir, .usb, &result);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn scanDirRecursive(
    allocator: std.mem.Allocator,
    sysfs_inst: *const Sysfs,
    dir_path: []const u8,
    bus: Bus,
    result: *std.ArrayList(Config),
) !void {
    const entries = sysfs_inst.readDir(allocator, dir_path) catch return;
    defer {
        for (entries) |e| allocator.free(e);
        allocator.free(entries);
    }

    for (entries) |entry| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry });
        defer allocator.free(child_path);

        if (std.mem.eql(u8, entry, "PROBECONFIG")) {
            if (config.parseFile(allocator, child_path, dir_path, bus)) |cfg| {
                try result.append(allocator, cfg);
            } else |_| {
                // Warnings on corrupt/unparseable configs as per spec
            }
        } else if (sysfs.isDir(child_path)) {
            try scanDirRecursive(allocator, sysfs_inst, child_path, bus, result);
        }
    }
}

/// Reads installed configurations from `state_file_path`.
pub fn loadInstalled(
    allocator: std.mem.Allocator,
    state_file_path: []const u8,
    bus_filter: cli.BusFilter,
) ![]InstalledConfig {
    const content = sysfs.readFile(allocator, state_file_path) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(InstalledConfig, 0),
        else => return err,
    };
    defer allocator.free(content);

    return parseStateToml(allocator, content, bus_filter);
}

/// Saves installed configurations to `state_file_path`.
pub fn saveInstalled(
    allocator: std.mem.Allocator,
    state_file_path: []const u8,
    configs: []const InstalledConfig,
) !void {
    if (std.fs.path.dirname(state_file_path)) |dir| {
        ensureDirExists(allocator, dir);
    }

    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        state_file_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch return error.WriteError;
    defer _ = std.os.linux.close(fd);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (configs) |cfg| {
        const bus_str = switch (cfg.bus) {
            .pci => "pci",
            .usb => "usb",
        };
        try out.appendSlice(allocator, "[[installed]]\n");
        const line = try std.fmt.allocPrint(allocator, "name = \"{s}\"\nbus = \"{s}\"\nsource = \"{s}\"\nhooks_dir = \"{s}\"\n", .{
            cfg.name, bus_str, cfg.source, cfg.hooks_dir,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);

        try appendTomlArray(allocator, &out, "depends", cfg.depends);
        try appendTomlArray(allocator, &out, "conflicts", cfg.conflicts);
        try appendTomlArray(allocator, &out, "kernel_depends", cfg.kernel_depends);
        try appendTomlArray(allocator, &out, "kernel_conflicts", cfg.kernel_conflicts);
        try out.append(allocator, '\n');
    }

    _ = std.os.linux.write(fd, out.items.ptr, out.items.len);
}

fn appendTomlArray(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, items: []const []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, " = [");
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '"');
        try out.appendSlice(allocator, item);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]\n");
}

fn ensureDirExists(allocator: std.mem.Allocator, dir: []const u8) void {
    if (dir.len == 0 or sysfs.isDir(dir)) return;
    if (std.fs.path.dirname(dir)) |parent| {
        ensureDirExists(allocator, parent);
    }
    const dir_z = allocator.dupeZ(u8, dir) catch return;
    defer allocator.free(dir_z);
    _ = std.os.linux.mkdirat(std.posix.AT.FDCWD, dir_z, 0o755);
}

fn parseStateToml(
    allocator: std.mem.Allocator,
    content: []const u8,
    bus_filter: cli.BusFilter,
) ![]InstalledConfig {
    var result = std.ArrayList(InstalledConfig).empty;
    errdefer {
        for (result.items) |*cfg| cfg.deinit(allocator);
        result.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current: ?InstalledConfig = null;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[installed]]")) {
            if (current) |c| {
                if (busFilterMatches(c.bus, bus_filter)) {
                    try result.append(allocator, c);
                } else {
                    var tmp = c;
                    tmp.deinit(allocator);
                }
            }
            current = InstalledConfig{
                .name = try allocator.dupe(u8, ""),
                .bus = .pci,
                .source = try allocator.dupe(u8, ""),
                .depends = try allocator.alloc([]const u8, 0),
                .conflicts = try allocator.alloc([]const u8, 0),
                .kernel_depends = try allocator.alloc([]const u8, 0),
                .kernel_conflicts = try allocator.alloc([]const u8, 0),
                .hooks_dir = try allocator.dupe(u8, ""),
            };
            continue;
        }

        if (current) |*curr| {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

                if (std.mem.eql(u8, key, "name")) {
                    allocator.free(curr.name);
                    curr.name = try extractTomlString(allocator, val);
                } else if (std.mem.eql(u8, key, "bus")) {
                    const bus_str = try extractTomlString(allocator, val);
                    defer allocator.free(bus_str);
                    curr.bus = if (std.mem.eql(u8, bus_str, "usb")) .usb else .pci;
                } else if (std.mem.eql(u8, key, "source")) {
                    allocator.free(curr.source);
                    curr.source = try extractTomlString(allocator, val);
                } else if (std.mem.eql(u8, key, "hooks_dir")) {
                    allocator.free(curr.hooks_dir);
                    curr.hooks_dir = try extractTomlString(allocator, val);
                } else if (std.mem.eql(u8, key, "depends")) {
                    for (curr.depends) |s| allocator.free(s);
                    allocator.free(curr.depends);
                    curr.depends = try extractTomlStringArray(allocator, val);
                } else if (std.mem.eql(u8, key, "conflicts")) {
                    for (curr.conflicts) |s| allocator.free(s);
                    allocator.free(curr.conflicts);
                    curr.conflicts = try extractTomlStringArray(allocator, val);
                } else if (std.mem.eql(u8, key, "kernel_depends")) {
                    for (curr.kernel_depends) |s| allocator.free(s);
                    allocator.free(curr.kernel_depends);
                    curr.kernel_depends = try extractTomlStringArray(allocator, val);
                } else if (std.mem.eql(u8, key, "kernel_conflicts")) {
                    for (curr.kernel_conflicts) |s| allocator.free(s);
                    allocator.free(curr.kernel_conflicts);
                    curr.kernel_conflicts = try extractTomlStringArray(allocator, val);
                }
            }
        }
    }

    if (current) |c| {
        if (busFilterMatches(c.bus, bus_filter)) {
            try result.append(allocator, c);
        } else {
            var tmp = c;
            tmp.deinit(allocator);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn busFilterMatches(bus: Bus, filter: cli.BusFilter) bool {
    return switch (filter) {
        .both => true,
        .pci => bus == .pci,
        .usb => bus == .usb,
    };
}

fn extractTomlString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\"");
    return allocator.dupe(u8, trimmed);
}

fn extractTomlStringArray(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r[]");
    if (trimmed.len == 0) return try allocator.alloc([]const u8, 0);

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\"");
        if (item.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, item));
        }
    }

    return list.toOwnedSlice(allocator);
}
