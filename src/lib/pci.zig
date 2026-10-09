const std = @import("std");
const Sysfs = @import("sysfs.zig").Sysfs;
const Device = @import("device.zig").Device;
const Bus = @import("device.zig").Bus;
const pciClassName = @import("device.zig").pciClassName;
const names = @import("names.zig");

/// Enumerates all PCI devices from sysfs.
pub fn enumerate(allocator: std.mem.Allocator, sysfs: *const Sysfs) ![]Device {
    const devices_path = try sysfs.path(allocator, &.{ "bus", "pci", "devices" });
    defer allocator.free(devices_path);

    const entries = sysfs.readDir(allocator, devices_path) catch |err| switch (err) {
        error.DirNotFound => return try allocator.alloc(Device, 0),
        else => return err,
    };
    defer {
        for (entries) |name| allocator.free(name);
        allocator.free(entries);
    }

    var result = std.ArrayList(Device).empty;
    errdefer {
        for (result.items) |*dev| dev.deinit(allocator);
        result.deinit(allocator);
    }

    for (entries) |entry| {
        if (enumerateOne(allocator, sysfs, devices_path, entry)) |dev| {
            try result.append(allocator, dev);
        } else |_| {}
    }

    return result.toOwnedSlice(allocator);
}

fn enumerateOne(
    allocator: std.mem.Allocator,
    sysfs: *const Sysfs,
    devices_path: []const u8,
    entry: []const u8,
) !Device {
    const dev_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ devices_path, entry });
    defer allocator.free(dev_path);

    const class_path = try std.fmt.allocPrint(allocator, "{s}/class", .{dev_path});
    defer allocator.free(class_path);
    const class_raw = sysfs.readFile(allocator, class_path) catch null;
    defer if (class_raw) |r| allocator.free(r);

    const vendor_path = try std.fmt.allocPrint(allocator, "{s}/vendor", .{dev_path});
    defer allocator.free(vendor_path);
    const vendor_raw = sysfs.readFile(allocator, vendor_path) catch null;
    defer if (vendor_raw) |r| allocator.free(r);

    const device_path = try std.fmt.allocPrint(allocator, "{s}/device", .{dev_path});
    defer allocator.free(device_path);
    const device_raw = sysfs.readFile(allocator, device_path) catch null;
    defer if (device_raw) |r| allocator.free(r);

    if (class_raw == null and vendor_raw == null and device_raw == null) {
        return error.NotADevice;
    }

    const class_code = if (class_raw) |raw| parseHex4(raw) catch [4]u8{ '0', '0', '0', '0' } else [4]u8{ '0', '0', '0', '0' };
    const vendor_id = if (vendor_raw) |raw| parseHex4(raw) catch [4]u8{ '0', '0', '0', '0' } else [4]u8{ '0', '0', '0', '0' };
    const device_id = if (device_raw) |raw| parseHex4(raw) catch [4]u8{ '0', '0', '0', '0' } else [4]u8{ '0', '0', '0', '0' };

    const class_name = pciClassName(&class_code);
    const dev_names = names.lookupPci(allocator, &vendor_id, &device_id) catch names.DeviceNames{
        .vendor_name = try allocator.dupe(u8, ""),
        .device_name = try allocator.dupe(u8, ""),
    };

    return Device{
        .bus = .pci,
        .id = try allocator.dupe(u8, entry),
        .class_id = try allocator.dupe(u8, &class_code),
        .vendor_id = try allocator.dupe(u8, &vendor_id),
        .device_id = try allocator.dupe(u8, &device_id),
        .class_name = try allocator.dupe(u8, class_name),
        .vendor_name = dev_names.vendor_name,
        .device_name = dev_names.device_name,
    };
}

/// Parses a hex string like "0x030000" into a 4-char lowercase hex string.
/// For PCI class codes (e.g. "0x030000"), the first 4 hex digits represent
/// the base class and subclass.
/// For vendor and device IDs (e.g. "0x8086"), returns the 4 hex digits.
fn parseHex4(raw: []const u8) ![4]u8 {
    var start: usize = 0;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        start = 2;
    }
    const hex_part = raw[start..];
    if (hex_part.len == 0) return error.InvalidHex;

    var buf: [4]u8 = .{ '0', '0', '0', '0' };
    if (hex_part.len >= 4) {
        for (0..4) |i| {
            buf[i] = std.ascii.toLower(hex_part[i]);
        }
    } else {
        const offset = 4 - hex_part.len;
        for (hex_part, 0..) |c, i| {
            buf[offset + i] = std.ascii.toLower(c);
        }
    }
    return buf;
}
