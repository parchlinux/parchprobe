const std = @import("std");

pub const Bus = enum { pci, usb };

/// A detected hardware device. All string fields are owned by the caller's
/// allocator and must be freed after use.
pub const Device = struct {
    bus: Bus,
    /// Sysfs device ID (e.g., "0000:01:00.0" for PCI, "1-1" for USB).
    id: []const u8,
    /// 4-hex-digit lowercase class ID.
    class_id: []const u8,
    /// 4-hex-digit lowercase vendor ID.
    vendor_id: []const u8,
    /// 4-hex-digit lowercase device ID.
    device_id: []const u8,
    /// Human-readable class name (e.g., "VGA compatible controller").
    class_name: []const u8,
    /// Human-readable vendor name.
    vendor_name: []const u8,
    /// Human-readable device name.
    device_name: []const u8,

    pub fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.class_id);
        allocator.free(self.vendor_id);
        allocator.free(self.device_id);
        allocator.free(self.class_name);
        allocator.free(self.vendor_name);
        allocator.free(self.device_name);
    }
};

/// Common PCI class code → name mapping (factual data from the PCI ID
/// repository specification).
pub fn pciClassName(class_code: []const u8) []const u8 {
    if (class_code.len < 2) return "Unknown";
    const code = class_code[0..2];
    if (std.mem.eql(u8, code, "00")) return "Unclassified device";
    if (std.mem.eql(u8, code, "01")) return "Mass storage controller";
    if (std.mem.eql(u8, code, "02")) return "Network controller";
    if (std.mem.eql(u8, code, "03")) return "Display controller";
    if (std.mem.eql(u8, code, "04")) return "Multimedia controller";
    if (std.mem.eql(u8, code, "05")) return "Memory controller";
    if (std.mem.eql(u8, code, "06")) return "Bridge";
    if (std.mem.eql(u8, code, "07")) return "Communication controller";
    if (std.mem.eql(u8, code, "08")) return "Generic system peripheral";
    if (std.mem.eql(u8, code, "09")) return "Input device controller";
    if (std.mem.eql(u8, code, "0a")) return "Docking station";
    if (std.mem.eql(u8, code, "0b")) return "Processor";
    if (std.mem.eql(u8, code, "0c")) return "Serial bus controller";
    if (std.mem.eql(u8, code, "0d")) return "Wireless controller";
    if (std.mem.eql(u8, code, "0e")) return "Intelligent controller";
    if (std.mem.eql(u8, code, "0f")) return "Satellite communications controller";
    if (std.mem.eql(u8, code, "10")) return "Encryption controller";
    if (std.mem.eql(u8, code, "11")) return "Signal processing controller";
    if (std.mem.eql(u8, code, "12")) return "Processing accelerators";
    if (std.mem.eql(u8, code, "13")) return "Non-Essential Instrumentation";
    if (std.mem.eql(u8, code, "40")) return "Coprocessor";
    return "Unknown";
}

/// USB class code → name mapping.
pub fn usbClassName(class_code: []const u8) []const u8 {
    if (class_code.len < 2) return "Unknown";
    const code = class_code[0..2];
    if (std.mem.eql(u8, code, "00")) return "Per-interface";
    if (std.mem.eql(u8, code, "01")) return "Audio";
    if (std.mem.eql(u8, code, "02")) return "Communications and CDC Control";
    if (std.mem.eql(u8, code, "03")) return "Human Interface Device";
    if (std.mem.eql(u8, code, "05")) return "Physical Interface Device";
    if (std.mem.eql(u8, code, "06")) return "Image";
    if (std.mem.eql(u8, code, "07")) return "Printer";
    if (std.mem.eql(u8, code, "08")) return "Mass Storage";
    if (std.mem.eql(u8, code, "09")) return "Hub";
    if (std.mem.eql(u8, code, "0a")) return "CDC Data";
    if (std.mem.eql(u8, code, "0b")) return "Smart Card";
    if (std.mem.eql(u8, code, "0d")) return "Content Security";
    if (std.mem.eql(u8, code, "0e")) return "Video";
    if (std.mem.eql(u8, code, "0f")) return "Personal Healthcare";
    if (std.mem.eql(u8, code, "10")) return "Audio/Video Devices";
    if (std.mem.eql(u8, code, "11")) return "Billboard Device";
    if (std.mem.eql(u8, code, "12")) return "USB Type-C Bridge";
    if (std.mem.eql(u8, code, "dc")) return "Diagnostic Device";
    if (std.mem.eql(u8, code, "e0")) return "Wireless Controller";
    if (std.mem.eql(u8, code, "ef")) return "Miscellaneous";
    if (std.mem.eql(u8, code, "fe")) return "Application Specific";
    return "Unknown";
}
