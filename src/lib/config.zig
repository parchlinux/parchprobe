const std = @import("std");
const Bus = @import("device.zig").Bus;
const sysfs = @import("sysfs.zig");

pub const HardwareGroup = struct {
    class_ids: [][]const u8,
    vendor_ids: [][]const u8,
    device_ids: [][]const u8,
    device_ids_file: ?[]const u8 = null,
    blacklist_class_ids: [][]const u8,
    blacklist_vendor_ids: [][]const u8,
    blacklist_device_ids: [][]const u8,

    pub fn deinit(self: *HardwareGroup, allocator: std.mem.Allocator) void {
        for (self.class_ids) |s| allocator.free(s);
        allocator.free(self.class_ids);
        for (self.vendor_ids) |s| allocator.free(s);
        allocator.free(self.vendor_ids);
        for (self.device_ids) |s| allocator.free(s);
        allocator.free(self.device_ids);
        if (self.device_ids_file) |f| allocator.free(f);
        for (self.blacklist_class_ids) |s| allocator.free(s);
        allocator.free(self.blacklist_class_ids);
        for (self.blacklist_vendor_ids) |s| allocator.free(s);
        allocator.free(self.blacklist_vendor_ids);
        for (self.blacklist_device_ids) |s| allocator.free(s);
        allocator.free(self.blacklist_device_ids);
    }
};

pub const Config = struct {
    name: []const u8,
    info: []const u8,
    version: []const u8,
    freedriver: bool = true,
    priority: i32 = 0,
    hardware: []HardwareGroup,
    conflicts: [][]const u8,
    depends: [][]const u8,
    config_conflicts: [][]const u8,
    kernel_depends: [][]const u8,
    kernel_conflicts: [][]const u8,
    hooks_dir: []const u8,
    source_path: []const u8,
    bus: Bus = .pci,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.info);
        allocator.free(self.version);
        for (self.hardware) |*hw| hw.deinit(allocator);
        allocator.free(self.hardware);
        for (self.conflicts) |s| allocator.free(s);
        allocator.free(self.conflicts);
        for (self.depends) |s| allocator.free(s);
        allocator.free(self.depends);
        for (self.config_conflicts) |s| allocator.free(s);
        allocator.free(self.config_conflicts);
        for (self.kernel_depends) |s| allocator.free(s);
        allocator.free(self.kernel_depends);
        for (self.kernel_conflicts) |s| allocator.free(s);
        allocator.free(self.kernel_conflicts);
        allocator.free(self.hooks_dir);
        allocator.free(self.source_path);
    }
};

pub const ParseError = error{
    FileNotFound,
    ReadError,
    MissingName,
    ParseError,
    OutOfMemory,
};

/// Parses a PROBECONFIG file from disk at `file_path`.
/// `source_path` is the directory containing PROBECONFIG (used for relative file includes like device_ids_file).
/// `bus` specifies the bus type (.pci or .usb).
pub fn parseFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source_path: []const u8,
    bus: Bus,
) ParseError!Config {
    const content = sysfs.readFile(allocator, file_path) catch |err| switch (err) {
        error.FileNotFound => return ParseError.FileNotFound,
        else => return ParseError.ReadError,
    };
    defer allocator.free(content);

    return parseString(allocator, content, source_path, bus);
}

/// Parses PROBECONFIG content from a string.
pub fn parseString(
    allocator: std.mem.Allocator,
    content: []const u8,
    source_path: []const u8,
    bus: Bus,
) ParseError!Config {
    var p = Parser.init(allocator, content, source_path);
    return p.parse(bus);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
    pos: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8, source_path: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .source_path = source_path,
        };
    }

    fn parse(self: *Parser, bus: Bus) ParseError!Config {
        var name: ?[]const u8 = null;
        errdefer if (name) |n| self.allocator.free(n);
        var info: ?[]const u8 = null;
        errdefer if (info) |i| self.allocator.free(i);
        var version: ?[]const u8 = null;
        errdefer if (version) |v| self.allocator.free(v);
        var freedriver: bool = true;
        var priority: i32 = 0;
        var hooks_dir: ?[]const u8 = null;
        errdefer if (hooks_dir) |h| self.allocator.free(h);

        var conflicts = std.ArrayList([]const u8).empty;
        errdefer {
            for (conflicts.items) |s| self.allocator.free(s);
            conflicts.deinit(self.allocator);
        }

        var depends = std.ArrayList([]const u8).empty;
        errdefer {
            for (depends.items) |s| self.allocator.free(s);
            depends.deinit(self.allocator);
        }

        var config_conflicts = std.ArrayList([]const u8).empty;
        errdefer {
            for (config_conflicts.items) |s| self.allocator.free(s);
            config_conflicts.deinit(self.allocator);
        }

        var kernel_depends = std.ArrayList([]const u8).empty;
        errdefer {
            for (kernel_depends.items) |s| self.allocator.free(s);
            kernel_depends.deinit(self.allocator);
        }

        var kernel_conflicts = std.ArrayList([]const u8).empty;
        errdefer {
            for (kernel_conflicts.items) |s| self.allocator.free(s);
            kernel_conflicts.deinit(self.allocator);
        }

        var hardware_groups = std.ArrayList(HardwareGroup).empty;
        errdefer {
            for (hardware_groups.items) |*hw| hw.deinit(self.allocator);
            hardware_groups.deinit(self.allocator);
        }

        var current_group: ?*HardwareGroup = null;

        while (!self.isEof()) {
            self.skipWhitespaceAndComments();
            if (self.isEof()) break;

            if (self.peek() == '[') {
                if (self.matchExact("[[hardware]]")) {
                    const group = HardwareGroup{
                        .class_ids = try self.allocator.alloc([]const u8, 0),
                        .vendor_ids = try self.allocator.alloc([]const u8, 0),
                        .device_ids = try self.allocator.alloc([]const u8, 0),
                        .device_ids_file = null,
                        .blacklist_class_ids = try self.allocator.alloc([]const u8, 0),
                        .blacklist_vendor_ids = try self.allocator.alloc([]const u8, 0),
                        .blacklist_device_ids = try self.allocator.alloc([]const u8, 0),
                    };
                    try hardware_groups.append(self.allocator, group);
                    current_group = &hardware_groups.items[hardware_groups.items.len - 1];
                    continue;
                } else {
                    // Skip unsupported table header line
                    self.skipLine();
                    continue;
                }
            }

            const key = try self.parseKey();
            defer self.allocator.free(key);

            self.skipInlineWhitespace();
            if (self.peek() != '=') return ParseError.ParseError;
            _ = self.advance(); // '='
            self.skipInlineWhitespace();

            if (std.mem.eql(u8, key, "name")) {
                if (name) |n| self.allocator.free(n);
                name = try self.parseStringVal();
            } else if (std.mem.eql(u8, key, "info")) {
                if (info) |n| self.allocator.free(n);
                info = try self.parseStringVal();
            } else if (std.mem.eql(u8, key, "version")) {
                if (version) |n| self.allocator.free(n);
                version = try self.parseStringVal();
            } else if (std.mem.eql(u8, key, "freedriver")) {
                freedriver = try self.parseBoolVal();
            } else if (std.mem.eql(u8, key, "priority")) {
                priority = try self.parseIntVal();
            } else if (std.mem.eql(u8, key, "hooks_dir")) {
                if (hooks_dir) |h| self.allocator.free(h);
                hooks_dir = try self.parseStringVal();
            } else if (std.mem.eql(u8, key, "conflicts")) {
                const arr = try self.parseStringArray();
                for (conflicts.items) |s| self.allocator.free(s);
                conflicts.clearRetainingCapacity();
                try conflicts.appendSlice(self.allocator, arr);
                self.allocator.free(arr);
            } else if (std.mem.eql(u8, key, "depends")) {
                const arr = try self.parseStringArray();
                for (depends.items) |s| self.allocator.free(s);
                depends.clearRetainingCapacity();
                try depends.appendSlice(self.allocator, arr);
                self.allocator.free(arr);
            } else if (std.mem.eql(u8, key, "config_conflicts")) {
                const arr = try self.parseStringArray();
                for (config_conflicts.items) |s| self.allocator.free(s);
                config_conflicts.clearRetainingCapacity();
                try config_conflicts.appendSlice(self.allocator, arr);
                self.allocator.free(arr);
            } else if (std.mem.eql(u8, key, "kernel_depends")) {
                const arr = try self.parseStringArray();
                for (kernel_depends.items) |s| self.allocator.free(s);
                kernel_depends.clearRetainingCapacity();
                try kernel_depends.appendSlice(self.allocator, arr);
                self.allocator.free(arr);
            } else if (std.mem.eql(u8, key, "kernel_conflicts")) {
                const arr = try self.parseStringArray();
                for (kernel_conflicts.items) |s| self.allocator.free(s);
                kernel_conflicts.clearRetainingCapacity();
                try kernel_conflicts.appendSlice(self.allocator, arr);
                self.allocator.free(arr);
            } else if (current_group) |grp| {
                if (std.mem.eql(u8, key, "class_ids")) {
                    for (grp.class_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.class_ids);
                    grp.class_ids = try self.parseStringArray();
                } else if (std.mem.eql(u8, key, "vendor_ids")) {
                    for (grp.vendor_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.vendor_ids);
                    grp.vendor_ids = try self.parseStringArray();
                } else if (std.mem.eql(u8, key, "device_ids")) {
                    for (grp.device_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.device_ids);
                    grp.device_ids = try self.parseStringArray();
                } else if (std.mem.eql(u8, key, "device_ids_file")) {
                    if (grp.device_ids_file) |f| self.allocator.free(f);
                    const fname = try self.parseStringVal();
                    grp.device_ids_file = fname;

                    // Read external device IDs file if present
                    if (self.source_path.len > 0) {
                        const file_ids = try self.loadDeviceIdsFile(fname);
                        // Append to or replace device_ids
                        var combined = std.ArrayList([]const u8).empty;
                        errdefer {
                            for (combined.items) |s| self.allocator.free(s);
                            combined.deinit(self.allocator);
                        }
                        for (grp.device_ids) |id| try combined.append(self.allocator, id);
                        self.allocator.free(grp.device_ids);
                        for (file_ids) |id| try combined.append(self.allocator, id);
                        self.allocator.free(file_ids);
                        grp.device_ids = try combined.toOwnedSlice(self.allocator);
                    }
                } else if (std.mem.eql(u8, key, "blacklist_class_ids")) {
                    for (grp.blacklist_class_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.blacklist_class_ids);
                    grp.blacklist_class_ids = try self.parseStringArray();
                } else if (std.mem.eql(u8, key, "blacklist_vendor_ids")) {
                    for (grp.blacklist_vendor_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.blacklist_vendor_ids);
                    grp.blacklist_vendor_ids = try self.parseStringArray();
                } else if (std.mem.eql(u8, key, "blacklist_device_ids")) {
                    for (grp.blacklist_device_ids) |s| self.allocator.free(s);
                    self.allocator.free(grp.blacklist_device_ids);
                    grp.blacklist_device_ids = try self.parseStringArray();
                } else {
                    // Unknown key in hardware group, skip value
                    try self.skipValue();
                }
            } else {
                // Unknown top-level key, skip value
                try self.skipValue();
            }
        }

        if (name == null or name.?.len == 0) {
            return ParseError.MissingName;
        }

        return Config{
            .name = name.?,
            .info = info orelse try self.allocator.dupe(u8, ""),
            .version = version orelse try self.allocator.dupe(u8, ""),
            .freedriver = freedriver,
            .priority = priority,
            .hardware = try hardware_groups.toOwnedSlice(self.allocator),
            .conflicts = try conflicts.toOwnedSlice(self.allocator),
            .depends = try depends.toOwnedSlice(self.allocator),
            .config_conflicts = try config_conflicts.toOwnedSlice(self.allocator),
            .kernel_depends = try kernel_depends.toOwnedSlice(self.allocator),
            .kernel_conflicts = try kernel_conflicts.toOwnedSlice(self.allocator),
            .hooks_dir = hooks_dir orelse try self.allocator.dupe(u8, ""),
            .source_path = try self.allocator.dupe(u8, self.source_path),
            .bus = bus,
        };
    }

    fn loadDeviceIdsFile(self: *Parser, filename: []const u8) ![][]const u8 {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.source_path, filename });
        defer self.allocator.free(full_path);

        const content = sysfs.readFile(self.allocator, full_path) catch return try self.allocator.alloc([]const u8, 0);
        defer self.allocator.free(content);

        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            var trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOfScalar(u8, trimmed, '#')) |comment_idx| {
                trimmed = std.mem.trim(u8, trimmed[0..comment_idx], " \t\r");
            }
            if (trimmed.len > 0) {
                try list.append(self.allocator, try self.allocator.dupe(u8, trimmed));
            }
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (!self.isEof()) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return ParseError.ParseError;
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn parseStringVal(self: *Parser) ParseError![]const u8 {
        self.skipInlineWhitespace();
        if (self.isEof() or self.peek() != '"') return ParseError.ParseError;
        _ = self.advance(); // '"'

        var res = std.ArrayList(u8).empty;
        defer res.deinit(self.allocator);

        while (!self.isEof()) {
            const c = self.advance();
            if (c == '"') {
                return self.allocator.dupe(u8, res.items);
            } else if (c == '\\') {
                if (self.isEof()) return ParseError.ParseError;
                const esc = self.advance();
                switch (esc) {
                    'n' => try res.append(self.allocator, '\n'),
                    'r' => try res.append(self.allocator, '\r'),
                    't' => try res.append(self.allocator, '\t'),
                    '"' => try res.append(self.allocator, '"'),
                    '\\' => try res.append(self.allocator, '\\'),
                    else => try res.append(self.allocator, esc),
                }
            } else {
                try res.append(self.allocator, c);
            }
        }
        return ParseError.ParseError;
    }

    fn parseBoolVal(self: *Parser) ParseError!bool {
        self.skipInlineWhitespace();
        if (self.matchExact("true")) return true;
        if (self.matchExact("false")) return false;
        return ParseError.ParseError;
    }

    fn parseIntVal(self: *Parser) ParseError!i32 {
        self.skipInlineWhitespace();
        const start = self.pos;
        if (!self.isEof() and (self.peek() == '-' or self.peek() == '+')) {
            _ = self.advance();
        }
        while (!self.isEof() and std.ascii.isDigit(self.peek())) {
            _ = self.advance();
        }
        if (self.pos == start) return ParseError.ParseError;
        return std.fmt.parseInt(i32, self.source[start..self.pos], 10) catch ParseError.ParseError;
    }

    fn parseStringArray(self: *Parser) ParseError![][]const u8 {
        self.skipInlineWhitespace();
        if (self.isEof() or self.peek() != '[') return ParseError.ParseError;
        _ = self.advance(); // '['

        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }

        while (!self.isEof()) {
            self.skipWhitespaceAndComments();
            if (self.isEof()) return ParseError.ParseError;
            if (self.peek() == ']') {
                _ = self.advance();
                return list.toOwnedSlice(self.allocator);
            }

            const str = try self.parseStringVal();
            try list.append(self.allocator, str);

            self.skipWhitespaceAndComments();
            if (!self.isEof() and self.peek() == ',') {
                _ = self.advance();
            } else if (!self.isEof() and self.peek() == ']') {
                _ = self.advance();
                return list.toOwnedSlice(self.allocator);
            } else {
                return ParseError.ParseError;
            }
        }
        return ParseError.ParseError;
    }

    fn skipValue(self: *Parser) ParseError!void {
        self.skipInlineWhitespace();
        if (self.isEof()) return;
        if (self.peek() == '"') {
            const s = try self.parseStringVal();
            self.allocator.free(s);
        } else if (self.peek() == '[') {
            var depth: usize = 0;
            while (!self.isEof()) {
                const c = self.advance();
                if (c == '[') depth += 1;
                if (c == ']') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
        } else {
            while (!self.isEof() and self.peek() != '\n' and self.peek() != '#') {
                _ = self.advance();
            }
        }
    }

    fn skipInlineWhitespace(self: *Parser) void {
        while (!self.isEof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (!self.isEof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
            } else if (c == '#') {
                self.skipLine();
            } else {
                break;
            }
        }
    }

    fn skipLine(self: *Parser) void {
        while (!self.isEof()) {
            const c = self.advance();
            if (c == '\n') break;
        }
    }

    fn isEof(self: *const Parser) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.pos];
    }

    fn advance(self: *Parser) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn matchExact(self: *Parser, literal: []const u8) bool {
        if (self.source.len - self.pos < literal.len) return false;
        if (std.mem.eql(u8, self.source[self.pos .. self.pos + literal.len], literal)) {
            self.pos += literal.len;
            return true;
        }
        return false;
    }
};
