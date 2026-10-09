const std = @import("std");
const Sysfs = @import("sysfs.zig").Sysfs;
const Device = @import("device.zig").Device;
const Bus = @import("device.zig").Bus;
const usbClassName = @import("device.zig").usbClassName;
const names = @import("names.zig");

/// Enumerates all USB devices from sysfs.
pub fn enumerate(allocator: std.mem.Allocator, sysfs: *const Sysfs) ![]Device {
    const devices_path = try sysfs.path(allocator, &.{ "bus", "usb", "devices" });
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
        // Skip root hubs (named "usb1", "usb2", etc.)
        if (std.mem.startsWith(u8, entry, "usb")) continue;

        // Skip interface symlinks (named e.g. "1-3:1.0")
        if (std.mem.indexOfScalar(u8, entry, ':') != null) continue;

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

    const vendor_path = try std.fmt.allocPrint(allocator, "{s}/idVendor", .{dev_path});
    defer allocator.free(vendor_path);
    const vendor_raw = sysfs.readFile(allocator, vendor_path) catch return error.NotADevice;
    defer allocator.free(vendor_raw);

    const product_path = try std.fmt.allocPrint(allocator, "{s}/idProduct", .{dev_path});
    defer allocator.free(product_path);
    const product_raw = sysfs.readFile(allocator, product_path) catch return error.NotADevice;
    defer allocator.free(product_raw);

    const class_path = try std.fmt.allocPrint(allocator, "{s}/bDeviceClass", .{dev_path});
    defer allocator.free(class_path);
    const class_raw = sysfs.readFile(allocator, class_path) catch null;
    defer if (class_raw) |r| allocator.free(r);

    var class_code = if (class_raw) |r| normalizeHex(2, r) else [2]u8{ '0', '0' };

    // For composite or per-interface devices (bDeviceClass == "00" or "ef"),
    // inspect interface-level bInterfaceClass.
    if (std.mem.eql(u8, &class_code, "00") or std.mem.eql(u8, &class_code, "ef")) {
        if (readInterfaceClass(allocator, sysfs, dev_path, entry)) |iface_class| {
            class_code = iface_class;
        }
    }

    const vendor_id = normalizeHex(4, vendor_raw);
    const device_id = normalizeHex(4, product_raw);
    const class_name = usbClassName(&class_code);

    const dev_names = names.lookupUsb(allocator, &vendor_id, &device_id) catch names.DeviceNames{
        .vendor_name = try allocator.dupe(u8, ""),
        .device_name = try allocator.dupe(u8, ""),
    };

    return Device{
        .bus = .usb,
        .id = try allocator.dupe(u8, entry),
        .class_id = try allocator.dupe(u8, &class_code),
        .vendor_id = try allocator.dupe(u8, &vendor_id),
        .device_id = try allocator.dupe(u8, &device_id),
        .class_name = try allocator.dupe(u8, class_name),
        .vendor_name = dev_names.vendor_name,
        .device_name = dev_names.device_name,
    };
}

/// Looks for interface subdirectories in `dev_path` and reads `bInterfaceClass`.
fn readInterfaceClass(
    allocator: std.mem.Allocator,
    sysfs: *const Sysfs,
    dev_path: []const u8,
    entry: []const u8,
) ?[2]u8 {
    const sub_entries = sysfs.readDir(allocator, dev_path) catch return null;
    defer {
        for (sub_entries) |name| allocator.free(name);
        allocator.free(sub_entries);
    }

    for (sub_entries) |sub| {
        // Look for interface directories like "<entry>:1.0" or any containing ":"
        if (std.mem.startsWith(u8, sub, entry) and std.mem.indexOfScalar(u8, sub, ':') != null) {
            const iface_path = std.fmt.allocPrint(allocator, "{s}/{s}/bInterfaceClass", .{ dev_path, sub }) catch continue;
            defer allocator.free(iface_path);

            if (sysfs.readFile(allocator, iface_path)) |raw| {
                defer allocator.free(raw);
                const code = normalizeHex(2, raw);
                if (!std.mem.eql(u8, &code, "00")) {
                    return code;
                }
            } else |_| {}
        }
    }

    return null;
}

/// Normalizes a hex string to a fixed-width lowercase string.
fn normalizeHex(comptime N: usize, raw: []const u8) [N]u8 {
    var start: usize = 0;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        start = 2;
    }
    const hex_part = raw[start..];
    var buf: [N]u8 = undefined;
    @memset(buf[0..], '0');

    if (hex_part.len >= N) {
        for (0..N) |i| {
            buf[i] = std.ascii.toLower(hex_part[i]);
        }
    } else {
        const offset = N - hex_part.len;
        for (hex_part, 0..) |c, i| {
            buf[offset + i] = std.ascii.toLower(c);
        }
    }
    return buf;
}
