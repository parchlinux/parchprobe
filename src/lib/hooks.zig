const std = @import("std");
const Device = @import("device.zig").Device;
const Bus = @import("device.zig").Bus;

pub const HookPhase = enum {
    pre_install,
    post_install,
    pre_remove,
    post_remove,

    pub fn asString(self: HookPhase) []const u8 {
        return switch (self) {
            .pre_install => "pre-install",
            .post_install => "post-install",
            .pre_remove => "pre-remove",
            .post_remove => "post-remove",
        };
    }

    pub fn operation(self: HookPhase) []const u8 {
        return switch (self) {
            .pre_install, .post_install => "install",
            .pre_remove, .post_remove => "remove",
        };
    }
};

/// Normalizes PCI bus id to DD:DD.D (stripping leading domain 0000:).
/// Leaves USB or other buses unchanged.
pub fn normalizeBusId(bus: Bus, raw_id: []const u8) []const u8 {
    if (bus == .pci) {
        if (std.mem.indexOfScalar(u8, raw_id, ':')) |first_colon| {
            const rest = raw_id[first_colon + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, ':') != null) {
                return rest;
            }
        }
    }
    return raw_id;
}

/// Resolves the absolute path to a hook script if it exists and is executable.
pub fn resolveHookScript(
    allocator: std.mem.Allocator,
    config_source: []const u8,
    hooks_dir: []const u8,
    phase: HookPhase,
) !?[]const u8 {
    const phase_name = phase.asString();
    const script_path = if (hooks_dir.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ config_source, hooks_dir, phase_name })
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_source, phase_name });
    errdefer allocator.free(script_path);

    // Check if script exists and is executable
    const script_z = try allocator.dupeZ(u8, script_path);
    defer allocator.free(script_z);

    const fd = std.posix.openat(std.posix.AT.FDCWD, script_z, .{ .ACCMODE = .RDONLY }, 0) catch {
        allocator.free(script_path);
        return null;
    };
    _ = std.os.linux.close(fd);

    return script_path;
}

/// Runs hook for all matching devices.
pub fn runHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_source: []const u8,
    hooks_dir: []const u8,
    phase: HookPhase,
    matching_devices: []const Device,
) !void {
    const script_path = (try resolveHookScript(allocator, config_source, hooks_dir, phase)) orelse return;
    defer allocator.free(script_path);

    const config_probe_path = try std.fmt.allocPrint(allocator, "{s}/PROBECONFIG", .{config_source});
    defer allocator.free(config_probe_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PARCHPROBE_CONFIG", config_probe_path);
    try env_map.put("PARCHPROBE_OPERATION", phase.operation());

    for (matching_devices) |dev| {
        const norm_bus_id = normalizeBusId(dev.bus, dev.id);

        const argv = [_][]const u8{
            script_path,
            dev.class_id,
            dev.vendor_id,
            dev.device_id,
            norm_bus_id,
        };

        const res = std.process.run(allocator, io, .{
            .argv = &argv,
            .environ_map = &env_map,
        }) catch return error.HookExecutionFailed;
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }

        if (res.term != .exited or res.term.exited != 0) {
            return error.HookFailed;
        }
    }
}
