const std = @import("std");

pub const version = "0.1.0";

pub const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
};

pub const BusFilter = enum { both, pci, usb };

pub const ParseError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidBus,
    InvalidDriverType,
    NothingToDo,
    OutOfMemory,
};

pub const Options = struct {
    help: bool = false,
    version: bool = false,
    command: ?[]const u8 = null,
    bus: BusFilter = .both,
    detail: bool = false,
    force: bool = false,
    json: bool = false,
    pm_cache_dir: []const u8 = "",
    pm_config: []const u8 = "",
    pm_root: []const u8 = "",
};

fn isBus(name: []const u8) bool {
    return std.mem.eql(u8, name, "pci") or std.mem.eql(u8, name, "usb");
}

/// Parses CLI arguments. `positional` collects non-flag arguments after the
/// command; the caller owns and frees it.
pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    positional: *std.ArrayList([]const u8),
) ParseError!Options {
    var opts = Options{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            return opts;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            opts.version = true;
            return opts;
        } else if (std.mem.eql(u8, arg, "--pci")) {
            opts.bus = .pci;
        } else if (std.mem.eql(u8, arg, "--usb")) {
            opts.bus = .usb;
        } else if (std.mem.eql(u8, arg, "--detail")) {
            opts.detail = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--pmcachedir")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingOptionValue;
            opts.pm_cache_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--pmconfig")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingOptionValue;
            opts.pm_config = args[i];
        } else if (std.mem.eql(u8, arg, "--pmroot")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingOptionValue;
            opts.pm_root = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            return ParseError.UnknownOption;
        } else {
            if (opts.command == null) {
                opts.command = arg;
            } else {
                try positional.append(allocator, arg);
            }
        }
    }

    if (opts.command) |cmd| {
        if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "remove")) {
            if (positional.items.len < 2) return ParseError.NothingToDo;
            if (!isBus(positional.items[0])) return ParseError.InvalidBus;
        } else if (std.mem.eql(u8, cmd, "install-custom")) {
            if (positional.items.len < 2) return ParseError.NothingToDo;
            if (!isBus(positional.items[0])) return ParseError.InvalidBus;
        } else if (std.mem.eql(u8, cmd, "auto")) {
            if (positional.items.len < 3) return ParseError.NothingToDo;
            if (!isBus(positional.items[0])) return ParseError.InvalidBus;
            const dt = positional.items[1];
            if (!std.mem.eql(u8, dt, "free") and !std.mem.eql(u8, dt, "nonfree")) {
                return ParseError.InvalidDriverType;
            }
        }
    }

    return opts;
}

pub fn printHelp(writer: anytype) void {
    writer.print(
        \\parchprobe {s} — hardware detection and driver configuration for Parch GNU/Linux
        \\
        \\Usage: parchprobe [OPTIONS] <command> [args]
        \\
        \\Commands:
        \\  list                       List configs available for detected hardware (default)
        \\  list-all                   List every config in the database
        \\  list-installed             List installed configs
        \\  list-hardware              List detected devices
        \\  install <bus> <cfg…>       Install driver config(s) (root only)
        \\  remove <bus> <cfg…>        Remove driver config(s) (root only)
        \\  install-custom <bus> <p>   Install config from <path>/PROBECONFIG (root only)
        \\  auto <bus> <free|nonfree> <classid>
        \\                             Auto-install best config for a device class (root only)
        \\
        \\Options:
        \\  --pci, --usb               Restrict to one bus (default: both)
        \\  --detail                   Verbose listing
        \\  --force                    Reinstall / skip already-installed
        \\  --json                     Machine-readable output on stdout
        \\  --pmcachedir <path>        Package manager cache dir
        \\  --pmconfig <path>          Package manager config
        \\  --pmroot <path>            Package manager root
        \\  -h, --help                 Show this help
        \\  -v, --version              Show version
        \\
    , .{version}) catch {};
}

pub fn printVersion(writer: anytype) void {
    writer.print(
        \\parchprobe {s}
        \\Copyright (C) 2026 Parch Linux Developers
        \\License: AGPL-3.0-only
        \\
    , .{version}) catch {};
}
