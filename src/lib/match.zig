const std = @import("std");
const Device = @import("device.zig").Device;
const Config = @import("config.zig").Config;
const HardwareGroup = @import("config.zig").HardwareGroup;
const InstalledConfig = @import("db.zig").InstalledConfig;
const pci = @import("pci.zig");
const usb = @import("usb.zig");
const sysfs = @import("sysfs.zig");
const Sysfs = sysfs.Sysfs;
const cli = @import("../cli.zig");

/// Enumerates hardware devices according to the requested bus filter.
pub fn collectDevices(
    allocator: std.mem.Allocator,
    sysfs_inst: *const Sysfs,
    bus: cli.BusFilter,
) ![]Device {
    var devices = std.ArrayList(Device).empty;
    errdefer {
        for (devices.items) |*dev| dev.deinit(allocator);
        devices.deinit(allocator);
    }

    if (bus == .both or bus == .pci) {
        const pci_devs = try pci.enumerate(allocator, sysfs_inst);
        defer allocator.free(pci_devs);
        for (pci_devs) |dev| {
            try devices.append(allocator, dev);
        }
    }

    if (bus == .both or bus == .usb) {
        const usb_devs = try usb.enumerate(allocator, sysfs_inst);
        defer allocator.free(usb_devs);
        for (usb_devs) |dev| {
            try devices.append(allocator, dev);
        }
    }

    return devices.toOwnedSlice(allocator);
}

pub const DeviceAttachment = struct {
    device: Device,
    available: [][]const u8,
    installed: [][]const u8,

    pub fn deinit(self: *DeviceAttachment, allocator: std.mem.Allocator) void {
        self.device.deinit(allocator);
        for (self.available) |s| allocator.free(s);
        allocator.free(self.available);
        for (self.installed) |s| allocator.free(s);
        allocator.free(self.installed);
    }
};

/// Case-insensitive glob matching supporting '*', '?', and character classes '[...]'.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(text[t_idx]))) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '[') {
            const close_idx = std.mem.indexOfScalarPos(u8, pattern, p_idx + 1, ']') orelse {
                if (std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(text[t_idx])) {
                    p_idx += 1;
                    t_idx += 1;
                    continue;
                }
                return false;
            };
            const class_content = pattern[p_idx + 1 .. close_idx];
            if (matchCharClass(class_content, text[t_idx])) {
                p_idx = close_idx + 1;
                t_idx += 1;
            } else if (star_idx != null) {
                p_idx = star_idx.? + 1;
                match_idx += 1;
                t_idx = match_idx;
            } else {
                return false;
            }
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

fn matchCharClass(class_content: []const u8, c: u8) bool {
    const ch = std.ascii.toLower(c);
    var i: usize = 0;
    while (i < class_content.len) {
        if (i + 2 < class_content.len and class_content[i + 1] == '-') {
            const start = std.ascii.toLower(class_content[i]);
            const end = std.ascii.toLower(class_content[i + 2]);
            if (ch >= start and ch <= end) return true;
            i += 3;
        } else {
            if (ch == std.ascii.toLower(class_content[i])) return true;
            i += 1;
        }
    }
    return false;
}

/// Checks if a device matches a hardware group.
pub fn matchDeviceGroup(group: HardwareGroup, dev: Device) bool {
    // 1. Blacklist vetoes
    for (group.blacklist_class_ids) |pattern| {
        if (globMatch(pattern, dev.class_id)) return false;
    }
    for (group.blacklist_vendor_ids) |pattern| {
        if (globMatch(pattern, dev.vendor_id)) return false;
    }
    for (group.blacklist_device_ids) |pattern| {
        if (globMatch(pattern, dev.device_id)) return false;
    }

    // 2. Class match
    if (group.class_ids.len > 0) {
        var class_matched = false;
        for (group.class_ids) |pattern| {
            if (globMatch(pattern, dev.class_id)) {
                class_matched = true;
                break;
            }
        }
        if (!class_matched) return false;
    }

    // 3. Vendor match
    if (group.vendor_ids.len > 0) {
        var vendor_matched = false;
        for (group.vendor_ids) |pattern| {
            if (globMatch(pattern, dev.vendor_id)) {
                vendor_matched = true;
                break;
            }
        }
        if (!vendor_matched) return false;
    }

    // 4. Device match
    if (group.device_ids.len > 0) {
        var device_matched = false;
        for (group.device_ids) |pattern| {
            if (globMatch(pattern, dev.device_id)) {
                device_matched = true;
                break;
            }
        }
        if (!device_matched) return false;
    }

    return true;
}

/// Checks if a config is fully satisfiable by the system devices.
/// As per spec: all [[hardware]] groups must match at least one device on the system.
/// Returns true if all groups are satisfied.
pub fn isConfigSatisfied(cfg: Config, devices: []const Device) bool {
    if (cfg.hardware.len == 0) return false;

    for (cfg.hardware) |grp| {
        var group_has_device = false;
        for (devices) |dev| {
            if (dev.bus == cfg.bus and matchDeviceGroup(grp, dev)) {
                group_has_device = true;
                break;
            }
        }
        if (!group_has_device) return false;
    }

    return true;
}

/// Checks if a specific device is part of the matched set for a config on the system.
pub fn doesConfigMatchDevice(cfg: Config, dev: Device, all_devices: []const Device) bool {
    if (dev.bus != cfg.bus) return false;
    if (!isConfigSatisfied(cfg, all_devices)) return false;

    // Check if this specific device matches at least one group
    for (cfg.hardware) |grp| {
        if (matchDeviceGroup(grp, dev)) return true;
    }

    return false;
}

/// Attaches available and installed configs to detected devices.
pub fn attachConfigs(
    allocator: std.mem.Allocator,
    devices: []const Device,
    available_configs: []const Config,
    installed_configs: []const InstalledConfig,
) ![]DeviceAttachment {
    var result = std.ArrayList(DeviceAttachment).empty;
    errdefer {
        for (result.items) |*att| att.deinit(allocator);
        result.deinit(allocator);
    }

    for (devices) |dev| {
        var avail_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (avail_list.items) |s| allocator.free(s);
            avail_list.deinit(allocator);
        }

        var inst_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (inst_list.items) |s| allocator.free(s);
            inst_list.deinit(allocator);
        }

        // Collect matching available configs
        var matched_cfgs = std.ArrayList(Config).empty;
        defer matched_cfgs.deinit(allocator);

        for (available_configs) |cfg| {
            if (doesConfigMatchDevice(cfg, dev, devices)) {
                try matched_cfgs.append(allocator, cfg);
            }
        }

        // Sort by priority descending, then by name
        std.mem.sortUnstable(Config, matched_cfgs.items, {}, struct {
            fn less(_: void, a: Config, b: Config) bool {
                if (a.priority != b.priority) {
                    return a.priority > b.priority;
                }
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        // Deduplicate and append names
        for (matched_cfgs.items) |cfg| {
            var exists = false;
            for (avail_list.items) |existing_name| {
                if (std.mem.eql(u8, existing_name, cfg.name)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                try avail_list.append(allocator, try allocator.dupe(u8, cfg.name));
            }
        }

        // Collect matching installed configs
        for (installed_configs) |inst| {
            if (inst.bus == dev.bus) {
                // Check if installed config name is in avail_list or matches directly
                for (avail_list.items) |avail_name| {
                    if (std.mem.eql(u8, avail_name, inst.name)) {
                        try inst_list.append(allocator, try allocator.dupe(u8, inst.name));
                        break;
                    }
                }
            }
        }

        const dev_copy = Device{
            .bus = dev.bus,
            .id = try allocator.dupe(u8, dev.id),
            .class_id = try allocator.dupe(u8, dev.class_id),
            .vendor_id = try allocator.dupe(u8, dev.vendor_id),
            .device_id = try allocator.dupe(u8, dev.device_id),
            .class_name = try allocator.dupe(u8, dev.class_name),
            .vendor_name = try allocator.dupe(u8, dev.vendor_name),
            .device_name = try allocator.dupe(u8, dev.device_name),
        };

        try result.append(allocator, DeviceAttachment{
            .device = dev_copy,
            .available = try avail_list.toOwnedSlice(allocator),
            .installed = try inst_list.toOwnedSlice(allocator),
        });
    }

    return result.toOwnedSlice(allocator);
}
