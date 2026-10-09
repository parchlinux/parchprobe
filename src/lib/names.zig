const std = @import("std");

pub const DeviceNames = struct {
    vendor_name: []const u8,
    device_name: []const u8,
};

const KnownEntry = struct {
    vendor_id: []const u8,
    device_id: ?[]const u8,
    vendor_name: []const u8,
    device_name: ?[]const u8,
};

const known_pci = [_]KnownEntry{
    .{
        .vendor_id = "8086",
        .device_id = "1237",
        .vendor_name = "Intel Corporation",
        .device_name = "440FX - 82441FX PMC",
    },
    .{
        .vendor_id = "8086",
        .device_id = null,
        .vendor_name = "Intel Corporation",
        .device_name = null,
    },
    .{
        .vendor_id = "10de",
        .device_id = "1234",
        .vendor_name = "NVIDIA Corporation",
        .device_name = "GeForce Graphics Controller",
    },
    .{
        .vendor_id = "10de",
        .device_id = null,
        .vendor_name = "NVIDIA Corporation",
        .device_name = null,
    },
    .{
        .vendor_id = "10ec",
        .device_id = "8168",
        .vendor_name = "Realtek Semiconductor Co., Ltd.",
        .device_name = "RTL8111/8168/8411 PCI Express Gigabit Ethernet Controller",
    },
    .{
        .vendor_id = "10ec",
        .device_id = null,
        .vendor_name = "Realtek Semiconductor Co., Ltd.",
        .device_name = null,
    },
    .{
        .vendor_id = "1022",
        .device_id = null,
        .vendor_name = "Advanced Micro Devices, Inc. [AMD]",
        .device_name = null,
    },
    .{
        .vendor_id = "1002",
        .device_id = null,
        .vendor_name = "Advanced Micro Devices, Inc. [AMD/ATI]",
        .device_name = null,
    },
};

const known_usb = [_]KnownEntry{
    .{
        .vendor_id = "046d",
        .device_id = "c52b",
        .vendor_name = "Logitech, Inc.",
        .device_name = "Unifying Receiver",
    },
    .{
        .vendor_id = "046d",
        .device_id = "c077",
        .vendor_name = "Logitech, Inc.",
        .device_name = "Optical Mouse",
    },
    .{
        .vendor_id = "046d",
        .device_id = null,
        .vendor_name = "Logitech, Inc.",
        .device_name = null,
    },
    .{
        .vendor_id = "1d6b",
        .device_id = "0002",
        .vendor_name = "Linux Foundation",
        .device_name = "2.0 root hub",
    },
    .{
        .vendor_id = "1d6b",
        .device_id = "0003",
        .vendor_name = "Linux Foundation",
        .device_name = "3.0 root hub",
    },
    .{
        .vendor_id = "1d6b",
        .device_id = null,
        .vendor_name = "Linux Foundation",
        .device_name = null,
    },
};

pub fn lookupPci(allocator: std.mem.Allocator, vendor_id: []const u8, device_id: []const u8) !DeviceNames {
    var vendor_match: ?[]const u8 = null;
    var device_match: ?[]const u8 = null;

    // Check built-in table
    for (known_pci) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.vendor_id, vendor_id)) {
            if (vendor_match == null) vendor_match = entry.vendor_name;
            if (entry.device_id) |dev| {
                if (std.ascii.eqlIgnoreCase(dev, device_id)) {
                    device_match = entry.device_name;
                    break;
                }
            }
        }
    }

    // If both found or no hwdata file, return
    if (vendor_match != null and device_match != null) {
        return DeviceNames{
            .vendor_name = try allocator.dupe(u8, vendor_match.?),
            .device_name = try allocator.dupe(u8, device_match.?),
        };
    }

    // Try scanning /usr/share/hwdata/pci.ids if available on system
    if (lookupIdsFile(allocator, "/usr/share/hwdata/pci.ids", vendor_id, device_id)) |names| {
        return names;
    } else |_| {}

    return DeviceNames{
        .vendor_name = try allocator.dupe(u8, vendor_match orelse ""),
        .device_name = try allocator.dupe(u8, device_match orelse ""),
    };
}

pub fn lookupUsb(allocator: std.mem.Allocator, vendor_id: []const u8, device_id: []const u8) !DeviceNames {
    var vendor_match: ?[]const u8 = null;
    var device_match: ?[]const u8 = null;

    // Check built-in table
    for (known_usb) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.vendor_id, vendor_id)) {
            if (vendor_match == null) vendor_match = entry.vendor_name;
            if (entry.device_id) |dev| {
                if (std.ascii.eqlIgnoreCase(dev, device_id)) {
                    device_match = entry.device_name;
                    break;
                }
            }
        }
    }

    if (vendor_match != null and device_match != null) {
        return DeviceNames{
            .vendor_name = try allocator.dupe(u8, vendor_match.?),
            .device_name = try allocator.dupe(u8, device_match.?),
        };
    }

    if (lookupIdsFile(allocator, "/usr/share/hwdata/usb.ids", vendor_id, device_id)) |names| {
        return names;
    } else |_| {}

    return DeviceNames{
        .vendor_name = try allocator.dupe(u8, vendor_match orelse ""),
        .device_name = try allocator.dupe(u8, device_match orelse ""),
    };
}

/// Helper that scans standard pci.ids/usb.ids format for matching vendor and device.
fn lookupIdsFile(
    allocator: std.mem.Allocator,
    ids_path: []const u8,
    vendor_id: []const u8,
    device_id: []const u8,
) !DeviceNames {
    const fd = std.posix.openat(std.posix.AT.FDCWD, ids_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;
    var line_buf: [1024]u8 = undefined;
    var line_len: usize = 0;

    var in_vendor = false;
    var found_vendor: ?[]const u8 = null;
    var found_device: ?[]const u8 = null;

    defer {
        if (found_vendor) |v| allocator.free(v);
        if (found_device) |d| allocator.free(d);
    }

    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) break;

        for (buf[0..n]) |byte| {
            if (byte == '\n' or byte == '\r') {
                if (line_len > 0) {
                    const line = line_buf[0..line_len];
                    line_len = 0;

                    if (line[0] == '#') continue;

                    if (line[0] != '\t') {
                        // Vendor line: "8086  Intel Corporation"
                        if (in_vendor) {
                            // Moved past target vendor
                            break;
                        }
                        if (line.len >= 6 and std.ascii.eqlIgnoreCase(line[0..4], vendor_id)) {
                            in_vendor = true;
                            const rest = std.mem.trim(u8, line[4..], " \t");
                            found_vendor = try allocator.dupe(u8, rest);
                        }
                    } else if (in_vendor and line.len >= 2 and line[0] == '\t' and line[1] != '\t') {
                        // Device line: "\t1234  Device Name"
                        const rest = line[1..];
                        if (rest.len >= 6 and std.ascii.eqlIgnoreCase(rest[0..4], device_id)) {
                            const name = std.mem.trim(u8, rest[4..], " \t");
                            found_device = try allocator.dupe(u8, name);
                            break;
                        }
                    }
                }
            } else {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }

        if (found_device != null) break;
    }

    if (found_vendor != null) {
        const v = found_vendor.?;
        found_vendor = null; // take ownership
        const d = if (found_device) |dev| blk: {
            found_device = null;
            break :blk dev;
        } else try allocator.dupe(u8, "");

        return DeviceNames{
            .vendor_name = v,
            .device_name = d,
        };
    }

    return error.NotFound;
}
