const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const sysfs = @import("lib/sysfs.zig");
const device = @import("lib/device.zig");
const pci = @import("lib/pci.zig");
const usb = @import("lib/usb.zig");
const db = @import("lib/db.zig");
const match = @import("lib/match.zig");
const tx = @import("lib/tx.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const code = run(arena, io, args[1..], stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    std.process.exit(@intFromEnum(code));
}

/// CLI entry point. Kept separate from main() so it can be tested and reused.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    const opts = cli.parseArgs(allocator, args, &positional) catch |err| {
        switch (err) {
            error.UnknownOption => stderr.print("error: unknown option\n", .{}) catch {},
            error.MissingOptionValue => stderr.print("error: missing option value\n", .{}) catch {},
            error.InvalidBus => stderr.print("error: bus must be 'pci' or 'usb'\n", .{}) catch {},
            error.InvalidDriverType => stderr.print("error: driver type must be 'free' or 'nonfree'\n", .{}) catch {},
            error.NothingToDo => stderr.print("error: nothing to do\n", .{}) catch {},
            error.OutOfMemory => stderr.print("error: out of memory\n", .{}) catch {},
        }
        cli.printHelp(stderr);
        return .failure;
    };

    if (opts.help) {
        cli.printHelp(stdout);
        return .success;
    }
    if (opts.version) {
        cli.printVersion(stdout);
        return .success;
    }

    const cmd = opts.command orelse "list";

    if (std.mem.eql(u8, cmd, "list")) {
        return runList(allocator, opts, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "list-all")) {
        return runListAll(allocator, opts, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "list-installed")) {
        return runListInstalled(allocator, opts, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "list-hardware")) {
        return runListHardware(allocator, opts, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "install")) {
        return runInstall(allocator, io, opts, positional.items, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        return runRemove(allocator, io, opts, positional.items, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "auto")) {
        return runAuto(allocator, io, opts, positional.items, stdout, stderr);
    }

    stderr.print("error: command '{s}' not implemented yet\n", .{cmd}) catch {};
    return .failure;
}

fn collectDevices(
    allocator: std.mem.Allocator,
    sysfs_inst: *const sysfs.Sysfs,
    bus: cli.BusFilter,
    stderr: anytype,
) ?[]device.Device {
    var devices = std.ArrayList(device.Device).empty;
    errdefer {
        for (devices.items) |*dev| dev.deinit(allocator);
        devices.deinit(allocator);
    }

    if (bus == .both or bus == .pci) {
        const pci_devs = pci.enumerate(allocator, sysfs_inst) catch |err| {
            stderr.print("error: failed to enumerate PCI devices: {s}\n", .{@errorName(err)}) catch {};
            return null;
        };
        defer allocator.free(pci_devs);
        for (pci_devs) |dev| {
            devices.append(allocator, dev) catch return null;
        }
    }

    if (bus == .both or bus == .usb) {
        const usb_devs = usb.enumerate(allocator, sysfs_inst) catch |err| {
            stderr.print("error: failed to enumerate USB devices: {s}\n", .{@errorName(err)}) catch {};
            return null;
        };
        defer allocator.free(usb_devs);
        for (usb_devs) |dev| {
            devices.append(allocator, dev) catch return null;
        }
    }

    return devices.toOwnedSlice(allocator) catch null;
}

fn runListAll(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch |err| {
        stderr.print("error: failed to initialize sysfs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const db_root = db.getDbRoot(allocator) catch return .failure;
    defer allocator.free(db_root);

    const configs = db.discoverConfigs(allocator, &sysfs_inst, db_root, opts.bus) catch |err| {
        stderr.print("error: failed to discover configs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (configs) |*c| c.deinit(allocator);
        allocator.free(configs);
    }

    if (opts.json) {
        stdout.print("{{\"configs\": [", .{}) catch {};
        for (configs, 0..) |cfg, i| {
            const bus_str = switch (cfg.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            if (i > 0) stdout.print(",", .{}) catch {};
            stdout.print("{{\"name\":\"{s}\",\"bus\":\"{s}\",\"version\":\"{s}\",\"freedriver\":{s},\"priority\":{d}}}", .{
                cfg.name,
                bus_str,
                cfg.version,
                if (cfg.freedriver) "true" else "false",
                cfg.priority,
            }) catch {};
        }
        stdout.print("]}}\n", .{}) catch {};
    } else {
        stdout.print("{s:<20} {s:<15} {s:<6} {s}\n", .{ "NAME", "VERSION", "FREE", "BUS" }) catch {};
        stdout.print("{s:-<20} {s:-<15} {s:-<6} {s:-<5}\n", .{ "", "", "", "" }) catch {};
        for (configs) |cfg| {
            const bus_str = switch (cfg.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print("{s:<20} {s:<15} {s:<6} {s}\n", .{
                cfg.name,
                cfg.version,
                if (cfg.freedriver) "true" else "false",
                bus_str,
            }) catch {};
        }
    }

    return .success;
}

fn runListInstalled(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    const state_path = db.getStateFilePath(allocator) catch return .failure;
    defer allocator.free(state_path);

    const installed = db.loadInstalled(allocator, state_path, opts.bus) catch |err| {
        stderr.print("error: failed to load installed state: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (installed) |*c| c.deinit(allocator);
        allocator.free(installed);
    }

    if (opts.json) {
        stdout.print("{{\"installed\": [", .{}) catch {};
        for (installed, 0..) |inst, i| {
            const bus_str = switch (inst.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            if (i > 0) stdout.print(",", .{}) catch {};
            stdout.print("{{\"name\":\"{s}\",\"bus\":\"{s}\"}}", .{ inst.name, bus_str }) catch {};
        }
        stdout.print("]}}\n", .{}) catch {};
    } else {
        stdout.print("{s:<20} {s:<6} {s}\n", .{ "NAME", "BUS", "SOURCE" }) catch {};
        stdout.print("{s:-<20} {s:-<6} {s:-<20}\n", .{ "", "", "" }) catch {};
        for (installed) |inst| {
            const bus_str = switch (inst.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print("{s:<20} {s:<6} {s}\n", .{
                inst.name,
                bus_str,
                inst.source,
            }) catch {};
        }
    }

    return .success;
}

fn runList(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch |err| {
        stderr.print("error: failed to initialize sysfs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const devices = collectDevices(allocator, &sysfs_inst, opts.bus, stderr) orelse return .failure;
    defer {
        for (devices) |*dev| dev.deinit(allocator);
        allocator.free(devices);
    }

    const db_root = db.getDbRoot(allocator) catch return .failure;
    defer allocator.free(db_root);

    const available_cfgs = db.discoverConfigs(allocator, &sysfs_inst, db_root, opts.bus) catch |err| {
        stderr.print("error: failed to discover configs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (available_cfgs) |*c| c.deinit(allocator);
        allocator.free(available_cfgs);
    }

    const state_path = db.getStateFilePath(allocator) catch return .failure;
    defer allocator.free(state_path);

    const installed_cfgs = db.loadInstalled(allocator, state_path, opts.bus) catch |err| {
        stderr.print("error: failed to load installed configs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (installed_cfgs) |*c| c.deinit(allocator);
        allocator.free(installed_cfgs);
    }

    const attachments = match.attachConfigs(allocator, devices, available_cfgs, installed_cfgs) catch |err| {
        stderr.print("error: matching failed: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (attachments) |*att| att.deinit(allocator);
        allocator.free(attachments);
    }

    if (opts.json) {
        stdout.print("{{\"devices\": [", .{}) catch {};
        for (attachments, 0..) |att, i| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            if (i > 0) stdout.print(",", .{}) catch {};
            stdout.print("{{\"bus\":\"{s}\",\"id\":\"{s}\",\"class_id\":\"{s}\",\"vendor_id\":\"{s}\",\"device_id\":\"{s}\",\"available\":[", .{
                bus_str,
                att.device.id,
                att.device.class_id,
                att.device.vendor_id,
                att.device.device_id,
            }) catch {};
            for (att.available, 0..) |avail, ai| {
                if (ai > 0) stdout.print(",", .{}) catch {};
                stdout.print("\"{s}\"", .{avail}) catch {};
            }
            stdout.print("],\"installed\":[", .{}) catch {};
            for (att.installed, 0..) |inst, ii| {
                if (ii > 0) stdout.print(",", .{}) catch {};
                stdout.print("\"{s}\"", .{inst}) catch {};
            }
            stdout.print("]}}", .{}) catch {};
        }
        stdout.print("]}}\n", .{}) catch {};
    } else if (opts.detail) {
        for (attachments) |att| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print(">> Device: {s} ({s})\n", .{ att.device.id, bus_str }) catch {};
            stdout.print("   Class:       {s} [{s}]\n", .{ att.device.class_id, att.device.class_name }) catch {};
            if (att.device.vendor_name.len > 0) {
                stdout.print("   Vendor:      {s} [{s}]\n", .{ att.device.vendor_id, att.device.vendor_name }) catch {};
            } else {
                stdout.print("   Vendor:      {s}\n", .{ att.device.vendor_id }) catch {};
            }
            if (att.device.device_name.len > 0) {
                stdout.print("   Device:      {s} [{s}]\n", .{ att.device.device_id, att.device.device_name }) catch {};
            } else {
                stdout.print("   Device:      {s}\n", .{ att.device.device_id }) catch {};
            }

            stdout.print("   Installed:   ", .{}) catch {};
            if (att.installed.len == 0) {
                stdout.print("(none)\n", .{}) catch {};
            } else {
                for (att.installed, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }

            stdout.print("   Available:   ", .{}) catch {};
            if (att.available.len == 0) {
                stdout.print("(none)\n\n", .{}) catch {};
            } else {
                for (att.available, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n\n", .{}) catch {};
            }
        }
    } else {
        stdout.print("{s:<8} {s:<8} {s:<8} {s:<6} {s}\n", .{ "CLASS", "VENDOR", "DEVICE", "BUS", "CONFIGS" }) catch {};
        stdout.print("{s:-<8} {s:-<8} {s:-<8} {s:-<6} {s:-<7}\n", .{ "", "", "", "", "" }) catch {};
        for (attachments) |att| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print("{s:<8} {s:<8} {s:<8} {s:<6} ", .{
                att.device.class_id,
                att.device.vendor_id,
                att.device.device_id,
                bus_str,
            }) catch {};
            if (att.available.len == 0) {
                stdout.print("(none)\n", .{}) catch {};
            } else {
                for (att.available, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }
    }

    return .success;
}

fn runListHardware(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch |err| {
        stderr.print("error: failed to initialize sysfs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const devices = collectDevices(allocator, &sysfs_inst, opts.bus, stderr) orelse return .failure;
    defer {
        for (devices) |*dev| dev.deinit(allocator);
        allocator.free(devices);
    }

    const db_root = db.getDbRoot(allocator) catch return .failure;
    defer allocator.free(db_root);

    const available_cfgs = db.discoverConfigs(allocator, &sysfs_inst, db_root, opts.bus) catch |err| {
        stderr.print("error: failed to discover configs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (available_cfgs) |*c| c.deinit(allocator);
        allocator.free(available_cfgs);
    }

    const state_path = db.getStateFilePath(allocator) catch return .failure;
    defer allocator.free(state_path);

    const installed_cfgs = db.loadInstalled(allocator, state_path, opts.bus) catch |err| {
        stderr.print("error: failed to load installed configs: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (installed_cfgs) |*c| c.deinit(allocator);
        allocator.free(installed_cfgs);
    }

    const attachments = match.attachConfigs(allocator, devices, available_cfgs, installed_cfgs) catch |err| {
        stderr.print("error: matching failed: {s}\n", .{@errorName(err)}) catch {};
        return .failure;
    };
    defer {
        for (attachments) |*att| att.deinit(allocator);
        allocator.free(attachments);
    }

    if (opts.json) {
        stdout.print("{{\"devices\": [", .{}) catch {};
        for (attachments, 0..) |att, i| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            if (i > 0) stdout.print(",", .{}) catch {};
            stdout.print("{{\"bus\":\"{s}\",\"id\":\"{s}\",\"class_id\":\"{s}\",\"vendor_id\":\"{s}\",\"device_id\":\"{s}\",\"class_name\":\"{s}\",\"configs\":[", .{
                bus_str,
                att.device.id,
                att.device.class_id,
                att.device.vendor_id,
                att.device.device_id,
                att.device.class_name,
            }) catch {};
            for (att.available, 0..) |c, ci| {
                if (ci > 0) stdout.print(",", .{}) catch {};
                stdout.print("\"{s}\"", .{c}) catch {};
            }
            stdout.print("]}}", .{}) catch {};
        }
        stdout.print("]}}\n", .{}) catch {};
    } else if (opts.detail) {
        for (attachments) |att| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print(">> Device: {s} ({s})\n", .{ att.device.id, bus_str }) catch {};
            stdout.print("   Class:       {s} [{s}]\n", .{ att.device.class_id, att.device.class_name }) catch {};
            if (att.device.vendor_name.len > 0) {
                stdout.print("   Vendor:      {s} [{s}]\n", .{ att.device.vendor_id, att.device.vendor_name }) catch {};
            } else {
                stdout.print("   Vendor:      {s}\n", .{ att.device.vendor_id }) catch {};
            }
            if (att.device.device_name.len > 0) {
                stdout.print("   Device:      {s} [{s}]\n", .{ att.device.device_id, att.device.device_name }) catch {};
            } else {
                stdout.print("   Device:      {s}\n", .{ att.device.device_id }) catch {};
            }

            stdout.print("   Installed:   ", .{}) catch {};
            if (att.installed.len == 0) {
                stdout.print("(none)\n", .{}) catch {};
            } else {
                for (att.installed, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }

            stdout.print("   Available:   ", .{}) catch {};
            if (att.available.len == 0) {
                stdout.print("(none)\n\n", .{}) catch {};
            } else {
                for (att.available, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n\n", .{}) catch {};
            }
        }
    } else {
        stdout.print("{s:<8} {s:<8} {s:<8} {s:<6} {s}\n", .{ "CLASS", "VENDOR", "DEVICE", "BUS", "CONFIGS" }) catch {};
        stdout.print("{s:-<8} {s:-<8} {s:-<8} {s:-<6} {s:-<7}\n", .{ "", "", "", "", "" }) catch {};
        for (attachments) |att| {
            const bus_str = switch (att.device.bus) {
                .pci => "pci",
                .usb => "usb",
            };
            stdout.print("{s:<8} {s:<8} {s:<8} {s:<6} ", .{
                att.device.class_id,
                att.device.vendor_id,
                att.device.device_id,
                bus_str,
            }) catch {};
            if (att.available.len == 0) {
                stdout.print("(none)\n", .{}) catch {};
            } else {
                for (att.available, 0..) |c, ci| {
                    if (ci > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{c}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }
    }

    return .success;
}

fn runInstall(
    allocator: std.mem.Allocator,
    io: Io,
    opts: cli.Options,
    positional: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    if (positional.len < 2) {
        stderr.print("error: nothing to do (specify bus and config name)\n", .{}) catch {};
        return .failure;
    }
    const bus_str = positional[0];
    const bus: device.Bus = if (std.mem.eql(u8, bus_str, "usb")) .usb else .pci;
    const config_names = positional[1..];

    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch {
        stderr.print("error: cannot initialize sysfs\n", .{}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const tx_opts = tx.TransactionOptions{
        .force = opts.force,
        .pm_root = opts.pm_root,
        .pm_config = opts.pm_config,
        .pm_cache_dir = opts.pm_cache_dir,
    };

    if (!opts.json) {
        stdout.print(">> Starting install transaction for {s}...\n", .{config_names[0]}) catch {};
    }

    tx.installConfigs(allocator, io, &sysfs_inst, bus, config_names, tx_opts) catch |err| {
        if (opts.json) {
            stdout.print("{{\"status\": \"error\", \"message\": \"{s}\"}}\n", .{@errorName(err)}) catch {};
        } else {
            stderr.print("error: install transaction failed: {s}\n", .{@errorName(err)}) catch {};
        }
        return .failure;
    };

    if (opts.json) {
        stdout.print("{{\"status\": \"ok\"}}\n", .{}) catch {};
    } else {
        stdout.print(">> Transaction completed successfully.\n", .{}) catch {};
    }
    return .success;
}

fn runRemove(
    allocator: std.mem.Allocator,
    io: Io,
    opts: cli.Options,
    positional: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    if (positional.len < 2) {
        stderr.print("error: nothing to do (specify bus and config name)\n", .{}) catch {};
        return .failure;
    }
    const bus_str = positional[0];
    const bus: device.Bus = if (std.mem.eql(u8, bus_str, "usb")) .usb else .pci;
    const config_names = positional[1..];

    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch {
        stderr.print("error: cannot initialize sysfs\n", .{}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const tx_opts = tx.TransactionOptions{
        .force = opts.force,
        .pm_root = opts.pm_root,
        .pm_config = opts.pm_config,
        .pm_cache_dir = opts.pm_cache_dir,
    };

    if (!opts.json) {
        stdout.print(">> Starting remove transaction for {s}...\n", .{config_names[0]}) catch {};
    }

    tx.removeConfigs(allocator, io, &sysfs_inst, bus, config_names, tx_opts) catch |err| {
        if (opts.json) {
            stdout.print("{{\"status\": \"error\", \"message\": \"{s}\"}}\n", .{@errorName(err)}) catch {};
        } else {
            stderr.print("error: remove transaction failed: {s}\n", .{@errorName(err)}) catch {};
        }
        return .failure;
    };

    if (opts.json) {
        stdout.print("{{\"status\": \"ok\"}}\n", .{}) catch {};
    } else {
        stdout.print(">> Transaction completed successfully.\n", .{}) catch {};
    }
    return .success;
}

fn runAuto(
    allocator: std.mem.Allocator,
    io: Io,
    opts: cli.Options,
    positional: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) cli.ExitCode {
    if (positional.len < 3) {
        stderr.print("error: auto requires <bus> <free|nonfree> <classid>\n", .{}) catch {};
        return .failure;
    }
    const bus_str = positional[0];
    const bus: device.Bus = if (std.mem.eql(u8, bus_str, "usb")) .usb else .pci;
    const driver_type = positional[1];
    const class_id = positional[2];

    var sysfs_inst = sysfs.Sysfs.initFromEnv(allocator) catch {
        stderr.print("error: cannot initialize sysfs\n", .{}) catch {};
        return .failure;
    };
    defer sysfs_inst.deinit(allocator);

    const tx_opts = tx.TransactionOptions{
        .force = opts.force,
        .pm_root = opts.pm_root,
        .pm_config = opts.pm_config,
        .pm_cache_dir = opts.pm_cache_dir,
    };

    if (!opts.json) {
        stdout.print(">> Running auto driver configuration for {s} ({s})...\n", .{ class_id, driver_type }) catch {};
    }

    tx.autoInstall(allocator, io, &sysfs_inst, bus, driver_type, class_id, tx_opts) catch |err| {
        if (opts.json) {
            stdout.print("{{\"status\": \"error\", \"message\": \"{s}\"}}\n", .{@errorName(err)}) catch {};
        } else {
            stderr.print("error: auto configuration failed: {s}\n", .{@errorName(err)}) catch {};
        }
        return .failure;
    };

    if (opts.json) {
        stdout.print("{{\"status\": \"ok\"}}\n", .{}) catch {};
    } else {
        stdout.print(">> Auto configuration completed.\n", .{}) catch {};
    }
    return .success;
}

