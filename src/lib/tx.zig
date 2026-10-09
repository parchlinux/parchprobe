const std = @import("std");
const Bus = @import("device.zig").Bus;
const Device = @import("device.zig").Device;
const cli = @import("../cli.zig");
const sysfs = @import("sysfs.zig");
const Sysfs = sysfs.Sysfs;
const config = @import("config.zig");
const Config = config.Config;
const db = @import("db.zig");
const InstalledConfig = db.InstalledConfig;
const match = @import("match.zig");
const pacman = @import("pacman.zig");
const Pacman = pacman.Pacman;
const hooks = @import("hooks.zig");

pub const TransactionOptions = struct {
    force: bool = false,
    dry_run: bool = false,
    skip_pkg_ops: bool = false,
    allow_non_root: bool = false,
    bus_filter: cli.BusFilter = .both,
    pm_root: []const u8 = "",
    pm_config: []const u8 = "",
    pm_cache_dir: []const u8 = "",
    db_root: []const u8 = "",
    state_file: []const u8 = "",
};

pub const TransactionError = error{
    PermissionDenied,
    ConfigNotFound,
    AlreadyInstalled,
    NotInstalled,
    ConfigConflict,
    RequiredByInstalledConfig,
    HookFailed,
    PackageInstallFailed,
    PackageRemoveFailed,
    InvalidBus,
    OutOfMemory,
    WriteError,
};

/// Checks whether current user is root (uid 0).
pub fn checkRoot(opts: TransactionOptions) !void {
    if (opts.allow_non_root or opts.dry_run) return;
    if (std.os.linux.getuid() != 0) {
        return TransactionError.PermissionDenied;
    }
}

/// Checks if lib32 packages should be enabled.
pub fn isLib32Enabled(allocator: std.mem.Allocator) bool {
    const conf_path = "/etc/parchprobe-x86_64.conf";
    const fd = std.posix.openat(std.posix.AT.FDCWD, conf_path, .{ .ACCMODE = .RDONLY }, 0) catch return true;
    defer _ = std.os.linux.close(fd);

    var buf: [1024]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return true;
    const content = buf[0..n];
    _ = allocator;
    if (std.mem.indexOf(u8, content, "PARCHPROBE_LIB32=false") != null) {
        return false;
    }
    return true;
}

/// Filters out lib32 packages if lib32 is disabled.
pub fn filterLib32(allocator: std.mem.Allocator, pkgs: []const []const u8) ![][]const u8 {
    const enabled = isLib32Enabled(allocator);
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    for (pkgs) |p| {
        if (!enabled and std.mem.startsWith(u8, p, "lib32-")) {
            continue;
        }
        try list.append(allocator, p);
    }

    return list.toOwnedSlice(allocator);
}

/// Installs the specified config(s) by name on the given bus.
pub fn installConfigs(
    allocator: std.mem.Allocator,
    io: std.Io,
    sysfs_inst: *const Sysfs,
    bus: Bus,
    config_names: []const []const u8,
    opts: TransactionOptions,
) !void {
    try checkRoot(opts);

    const db_root = if (opts.db_root.len > 0)
        try allocator.dupe(u8, opts.db_root)
    else
        try db.getDbRoot(allocator);
    defer allocator.free(db_root);

    const bus_filter: cli.BusFilter = switch (bus) {
        .pci => .pci,
        .usb => .usb,
    };

    const discovered = try db.discoverConfigs(allocator, sysfs_inst, db_root, bus_filter);
    defer {
        for (discovered) |*c| c.deinit(allocator);
        allocator.free(discovered);
    }

    // Load installed state
    const state_file = if (opts.state_file.len > 0)
        try allocator.dupe(u8, opts.state_file)
    else
        try db.getStateFilePath(allocator);
    defer allocator.free(state_file);

    var installed = try db.loadInstalled(allocator, state_file, .both);
    defer {
        for (installed) |*c| c.deinit(allocator);
        allocator.free(installed);
    }

    // Detect hardware devices
    const devices = try match.collectDevices(allocator, sysfs_inst, bus_filter);
    defer {
        for (devices) |*d| d.deinit(allocator);
        allocator.free(devices);
    }

    // Init ALPM / Pacman
    var pm = try Pacman.init(allocator, .{
        .pm_root = opts.pm_root,
        .pm_config = opts.pm_config,
        .pm_cache_dir = opts.pm_cache_dir,
    });
    defer pm.deinit();

    var is_first_sync: bool = true;

    for (config_names) |name| {
        try installOneConfig(
            allocator,
            io,
            bus,
            name,
            discovered,
            &installed,
            devices,
            &pm,
            opts,
            state_file,
            &is_first_sync,
        );
    }
}

fn installOneConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    bus: Bus,
    name: []const u8,
    discovered: []const Config,
    installed: *[]InstalledConfig,
    devices: []const Device,
    pm: *Pacman,
    opts: TransactionOptions,
    state_file: []const u8,
    is_first_sync: *bool,
) !void {
    // 1. Locate config in discovered DB
    var target_cfg: ?*const Config = null;
    for (discovered) |*c| {
        if (std.mem.eql(u8, c.name, name)) {
            target_cfg = c;
            break;
        }
    }
    if (target_cfg == null) {
        return TransactionError.ConfigNotFound;
    }
    const cfg = target_cfg.?;

    // 2. Check if already installed
    var already_installed_idx: ?usize = null;
    for (installed.*, 0..) |*inst, idx| {
        if (std.mem.eql(u8, inst.name, name)) {
            already_installed_idx = idx;
            break;
        }
    }

    if (already_installed_idx) |_| {
        if (!opts.force) {
            return TransactionError.AlreadyInstalled;
        }
        // With --force, remove first
        try removeOneConfig(allocator, io, name, installed, devices, pm, opts, state_file);
    }

    // 3. Resolve config-level dependencies and install them first
    for (cfg.depends) |dep_name| {
        for (discovered) |*dep_cfg| {
            if (std.mem.eql(u8, dep_cfg.name, dep_name)) {
                // Check if already installed
                var is_dep_installed = false;
                for (installed.*) |*inst| {
                    if (std.mem.eql(u8, inst.name, dep_name)) {
                        is_dep_installed = true;
                        break;
                    }
                }
                if (!is_dep_installed) {
                    try installOneConfig(
                        allocator,
                        io,
                        bus,
                        dep_name,
                        discovered,
                        installed,
                        devices,
                        pm,
                        opts,
                        state_file,
                        is_first_sync,
                    );
                }
                break;
            }
        }
    }

    // 4. Check config_conflicts against installed config names
    for (cfg.config_conflicts) |conflict_pattern| {
        for (installed.*) |*inst| {
            if (match.globMatch(conflict_pattern, inst.name)) {
                return TransactionError.ConfigConflict;
            }
        }
    }

    // 5. Match devices for this config
    var matching_devices = std.ArrayList(Device).empty;
    defer matching_devices.deinit(allocator);

    for (devices) |d| {
        if (d.bus == bus and match.doesConfigMatchDevice(cfg.*, d, devices)) {
            try matching_devices.append(allocator, d);
        }
    }

    // 6. Run pre-install hooks
    if (!opts.dry_run and !opts.skip_pkg_ops) {
        hooks.runHook(
            allocator,
            io,
            cfg.source_path,
            cfg.hooks_dir,
            .pre_install,
            matching_devices.items,
        ) catch return TransactionError.HookFailed;
    }

    // 7. Package operations
    // a. Remove conflicting packages that are installed
    const exp_kconflicts = try pm.expandKernelPackages(allocator, cfg.kernel_conflicts);
    defer {
        for (exp_kconflicts) |s| allocator.free(s);
        allocator.free(exp_kconflicts);
    }

    var all_conflicts = std.ArrayList([]const u8).empty;
    defer all_conflicts.deinit(allocator);
    for (cfg.conflicts) |c| try all_conflicts.append(allocator, c);
    for (exp_kconflicts) |c| try all_conflicts.append(allocator, c);

    const conflicts_to_remove = try pm.filterInstalled(allocator, all_conflicts.items);
    defer {
        for (conflicts_to_remove) |s| allocator.free(s);
        allocator.free(conflicts_to_remove);
    }

    if (!opts.dry_run and !opts.skip_pkg_ops and conflicts_to_remove.len > 0) {
        pm.executeRemove(allocator, io, conflicts_to_remove) catch return TransactionError.PackageRemoveFailed;
    }

    // b. Install depends (+ kernel_depends) with --needed
    const exp_kdepends = try pm.expandKernelPackages(allocator, cfg.kernel_depends);
    defer {
        for (exp_kdepends) |s| allocator.free(s);
        allocator.free(exp_kdepends);
    }

    var all_depends = std.ArrayList([]const u8).empty;
    defer all_depends.deinit(allocator);

    for (cfg.depends) |dep| {
        // Exclude dependencies that are other configs
        var is_cfg = false;
        for (discovered) |*d| {
            if (std.mem.eql(u8, d.name, dep)) {
                is_cfg = true;
                break;
            }
        }
        if (!is_cfg) {
            try all_depends.append(allocator, dep);
        }
    }
    for (exp_kdepends) |kd| try all_depends.append(allocator, kd);

    const filtered_deps = try filterLib32(allocator, all_depends.items);
    defer allocator.free(filtered_deps);

    if (!opts.dry_run and !opts.skip_pkg_ops and filtered_deps.len > 0) {
        pm.executeInstall(allocator, io, filtered_deps, is_first_sync.*) catch return TransactionError.PackageInstallFailed;
        is_first_sync.* = false;
    }

    // 8. Run post-install hooks
    if (!opts.dry_run and !opts.skip_pkg_ops) {
        hooks.runHook(
            allocator,
            io,
            cfg.source_path,
            cfg.hooks_dir,
            .post_install,
            matching_devices.items,
        ) catch return TransactionError.HookFailed;
    }

    // 9. Record state in state.toml
    if (!opts.dry_run) {
        const new_inst = InstalledConfig{
            .name = try allocator.dupe(u8, cfg.name),
            .bus = bus,
            .source = try allocator.dupe(u8, cfg.source_path),
            .depends = try dupeStrings(allocator, filtered_deps),
            .conflicts = try dupeStrings(allocator, all_conflicts.items),
            .kernel_depends = try dupeStrings(allocator, cfg.kernel_depends),
            .kernel_conflicts = try dupeStrings(allocator, cfg.kernel_conflicts),
            .hooks_dir = try allocator.dupe(u8, cfg.hooks_dir),
        };

        var new_list = std.ArrayList(InstalledConfig).empty;
        defer new_list.deinit(allocator);

        for (installed.*) |item| {
            try new_list.append(allocator, item);
        }
        try new_list.append(allocator, new_inst);

        try db.saveInstalled(allocator, state_file, new_list.items);

        // Update in-memory installed slice
        allocator.free(installed.*);
        installed.* = try new_list.toOwnedSlice(allocator);
    }
}

/// Removes the specified config(s) by name on the given bus.
pub fn removeConfigs(
    allocator: std.mem.Allocator,
    io: std.Io,
    sysfs_inst: *const Sysfs,
    bus: Bus,
    config_names: []const []const u8,
    opts: TransactionOptions,
) !void {
    try checkRoot(opts);

    const bus_filter: cli.BusFilter = switch (bus) {
        .pci => .pci,
        .usb => .usb,
    };

    const state_file = if (opts.state_file.len > 0)
        try allocator.dupe(u8, opts.state_file)
    else
        try db.getStateFilePath(allocator);
    defer allocator.free(state_file);

    var installed = try db.loadInstalled(allocator, state_file, .both);
    defer {
        for (installed) |*c| c.deinit(allocator);
        allocator.free(installed);
    }

    const devices = try match.collectDevices(allocator, sysfs_inst, bus_filter);
    defer {
        for (devices) |*d| d.deinit(allocator);
        allocator.free(devices);
    }

    var pm = try Pacman.init(allocator, .{
        .pm_root = opts.pm_root,
        .pm_config = opts.pm_config,
        .pm_cache_dir = opts.pm_cache_dir,
    });
    defer pm.deinit();

    for (config_names) |name| {
        try removeOneConfig(allocator, io, name, &installed, devices, &pm, opts, state_file);
    }
}

fn removeOneConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    installed: *[]InstalledConfig,
    devices: []const Device,
    pm: *Pacman,
    opts: TransactionOptions,
    state_file: []const u8,
) !void {
    var found_idx: ?usize = null;
    for (installed.*, 0..) |*inst, idx| {
        if (std.mem.eql(u8, inst.name, name)) {
            found_idx = idx;
            break;
        }
    }
    if (found_idx == null) {
        return TransactionError.NotInstalled;
    }
    const idx = found_idx.?;
    const target = &installed.*[idx];

    // Check if required by any other installed config
    for (installed.*) |*other| {
        if (std.mem.eql(u8, other.name, name)) continue;
        for (other.depends) |dep| {
            if (std.mem.eql(u8, dep, name)) {
                return TransactionError.RequiredByInstalledConfig;
            }
        }
    }

    // Match devices for hooks
    var matching_devices = std.ArrayList(Device).empty;
    defer matching_devices.deinit(allocator);

    for (devices) |d| {
        if (d.bus == target.bus) {
            try matching_devices.append(allocator, d);
        }
    }

    // 1. Run pre-remove hooks
    if (!opts.dry_run and !opts.skip_pkg_ops) {
        hooks.runHook(
            allocator,
            io,
            target.source,
            target.hooks_dir,
            .pre_remove,
            matching_devices.items,
        ) catch return TransactionError.HookFailed;
    }

    // 2. Remove packages recorded in state.toml that are currently installed
    const exp_kdepends = try pm.expandKernelPackages(allocator, target.kernel_depends);
    defer {
        for (exp_kdepends) |s| allocator.free(s);
        allocator.free(exp_kdepends);
    }

    var pkgs_to_check = std.ArrayList([]const u8).empty;
    defer pkgs_to_check.deinit(allocator);
    for (target.depends) |p| try pkgs_to_check.append(allocator, p);
    for (exp_kdepends) |p| try pkgs_to_check.append(allocator, p);

    const pkgs_to_remove = try pm.filterInstalled(allocator, pkgs_to_check.items);
    defer {
        for (pkgs_to_remove) |s| allocator.free(s);
        allocator.free(pkgs_to_remove);
    }

    if (!opts.dry_run and !opts.skip_pkg_ops and pkgs_to_remove.len > 0) {
        pm.executeRemove(allocator, io, pkgs_to_remove) catch return TransactionError.PackageRemoveFailed;
    }

    // 3. Run post-remove hooks
    if (!opts.dry_run and !opts.skip_pkg_ops) {
        hooks.runHook(
            allocator,
            io,
            target.source,
            target.hooks_dir,
            .post_remove,
            matching_devices.items,
        ) catch return TransactionError.HookFailed;
    }

    // 4. Delete entry from state.toml
    if (!opts.dry_run) {
        var new_list = std.ArrayList(InstalledConfig).empty;
        defer new_list.deinit(allocator);

        for (installed.*, 0..) |*item, i| {
            if (i != idx) {
                try new_list.append(allocator, item.*);
            }
        }

        try db.saveInstalled(allocator, state_file, new_list.items);

        var removed = target.*;
        removed.deinit(allocator);

        allocator.free(installed.*);
        installed.* = try new_list.toOwnedSlice(allocator);
    }
}

/// Auto-selects and installs the highest priority matching config for a given device class.
pub fn autoInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    sysfs_inst: *const Sysfs,
    bus: Bus,
    driver_type: []const u8,
    class_id: []const u8,
    opts: TransactionOptions,
) !void {
    try checkRoot(opts);

    const is_free_only = std.mem.eql(u8, driver_type, "free");

    const db_root = if (opts.db_root.len > 0)
        try allocator.dupe(u8, opts.db_root)
    else
        try db.getDbRoot(allocator);
    defer allocator.free(db_root);

    const bus_filter: cli.BusFilter = switch (bus) {
        .pci => .pci,
        .usb => .usb,
    };

    const discovered = try db.discoverConfigs(allocator, sysfs_inst, db_root, bus_filter);
    defer {
        for (discovered) |*c| c.deinit(allocator);
        allocator.free(discovered);
    }

    const state_file = if (opts.state_file.len > 0)
        try allocator.dupe(u8, opts.state_file)
    else
        try db.getStateFilePath(allocator);
    defer allocator.free(state_file);

    const installed = try db.loadInstalled(allocator, state_file, bus_filter);
    defer {
        for (installed) |*c| c.deinit(allocator);
        allocator.free(installed);
    }

    const devices = try match.collectDevices(allocator, sysfs_inst, bus_filter);
    defer {
        for (devices) |*d| d.deinit(allocator);
        allocator.free(devices);
    }

    // Filter devices matching class_id
    var chosen_configs = std.ArrayList([]const u8).empty;
    defer {
        for (chosen_configs.items) |s| allocator.free(s);
        chosen_configs.deinit(allocator);
    }

    for (devices) |d| {
        if (!std.mem.eql(u8, d.class_id, class_id)) continue;

        // Find available configs for this device
        var matched = std.ArrayList(Config).empty;
        defer matched.deinit(allocator);

        for (discovered) |cfg| {
            if (is_free_only and !cfg.freedriver) continue;
            if (match.doesConfigMatchDevice(cfg, d, devices)) {
                try matched.append(allocator, cfg);
            }
        }

        if (matched.items.len == 0) continue;

        // Sort by priority descending
        std.mem.sort(Config, matched.items, {}, configPriorityDesc);

        const best = matched.items[0];

        // Skip if already installed and not forced
        var is_inst = false;
        for (installed) |inst| {
            if (std.mem.eql(u8, inst.name, best.name)) {
                is_inst = true;
                break;
            }
        }

        if (is_inst and !opts.force) continue;

        // Dedup chosen configs
        var already_chosen = false;
        for (chosen_configs.items) |chosen| {
            if (std.mem.eql(u8, chosen, best.name)) {
                already_chosen = true;
                break;
            }
        }

        if (!already_chosen) {
            try chosen_configs.append(allocator, try allocator.dupe(u8, best.name));
        }
    }

    if (chosen_configs.items.len == 0) return;

    try installConfigs(allocator, io, sysfs_inst, bus, chosen_configs.items, opts);
}

fn configPriorityDesc(_: void, a: Config, b: Config) bool {
    return a.priority > b.priority;
}

fn dupeStrings(allocator: std.mem.Allocator, slice: []const []const u8) ![][]const u8 {
    const res = try allocator.alloc([]const u8, slice.len);
    for (slice, 0..) |s, i| {
        res[i] = try allocator.dupe(u8, s);
    }
    return res;
}
