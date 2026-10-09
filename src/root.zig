const std = @import("std");
const testing = std.testing;

pub const cli = @import("cli.zig");
pub const sysfs = @import("lib/sysfs.zig");
pub const device = @import("lib/device.zig");
pub const pci = @import("lib/pci.zig");
pub const usb = @import("lib/usb.zig");
pub const names = @import("lib/names.zig");
pub const config = @import("lib/config.zig");
pub const db = @import("lib/db.zig");
pub const match = @import("lib/match.zig");
pub const alpm = @import("alpm");
pub const pacman = @import("lib/pacman.zig");
pub const hooks = @import("lib/hooks.zig");
pub const tx = @import("lib/tx.zig");

// CLI tests

test "parse --help" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    const opts = try cli.parseArgs(testing.allocator, &.{ "--help" }, &pos);
    try testing.expect(opts.help);
}

test "parse --version" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    const opts = try cli.parseArgs(testing.allocator, &.{ "--version" }, &pos);
    try testing.expect(opts.version);
}

test "parse list with --pci" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    const opts = try cli.parseArgs(testing.allocator, &.{ "--pci", "list" }, &pos);
    try testing.expect(opts.command != null);
    try testing.expectEqualStrings("list", opts.command.?);
    try testing.expect(opts.bus == .pci);
}

test "parse install" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    const opts = try cli.parseArgs(testing.allocator, &.{ "install", "pci", "video-nvidia" }, &pos);
    try testing.expectEqualStrings("install", opts.command.?);
    try testing.expectEqualStrings("pci", pos.items[0]);
    try testing.expectEqualStrings("video-nvidia", pos.items[1]);
}

test "parse auto" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    const opts = try cli.parseArgs(testing.allocator, &.{ "auto", "usb", "nonfree", "0c45" }, &pos);
    try testing.expectEqualStrings("auto", opts.command.?);
    try testing.expectEqualStrings("nonfree", pos.items[1]);
    try testing.expectEqualStrings("0c45", pos.items[2]);
}

test "unknown option" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    try testing.expectError(cli.ParseError.UnknownOption, cli.parseArgs(testing.allocator, &.{ "--bogus" }, &pos));
}

test "missing option value" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    try testing.expectError(cli.ParseError.MissingOptionValue, cli.parseArgs(testing.allocator, &.{ "--pmroot" }, &pos));
}

test "invalid bus" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    try testing.expectError(cli.ParseError.InvalidBus, cli.parseArgs(testing.allocator, &.{ "install", "isa", "video-nvidia" }, &pos));
}

test "invalid driver type" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    try testing.expectError(cli.ParseError.InvalidDriverType, cli.parseArgs(testing.allocator, &.{ "auto", "pci", "maybe", "0300" }, &pos));
}

test "nothing to do" {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(testing.allocator);
    try testing.expectError(cli.ParseError.NothingToDo, cli.parseArgs(testing.allocator, &.{ "install", "pci" }, &pos));
}

// Sysfs tests

test "sysfs path join" {
    var s = try sysfs.Sysfs.init(testing.allocator, "/fake/sys");
    defer s.deinit(testing.allocator);
    const p = try s.path(testing.allocator, &.{ "bus", "pci", "devices" });
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/fake/sys/bus/pci/devices", p);
}

test "sysfs read file" {
    var s = try sysfs.Sysfs.init(testing.allocator, "tests/fixtures/sysfs");
    defer s.deinit(testing.allocator);
    const content = try s.readFile(testing.allocator, "tests/fixtures/sysfs/bus/pci/devices/0000:00:02.0/class");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("0x030000", content);
}

test "sysfs read dir" {
    var s = try sysfs.Sysfs.init(testing.allocator, "tests/fixtures/sysfs");
    defer s.deinit(testing.allocator);
    const entries = try s.readDir(testing.allocator, "tests/fixtures/sysfs/bus/pci/devices");
    defer {
        for (entries) |name| testing.allocator.free(name);
        testing.allocator.free(entries);
    }
    try testing.expect(entries.len == 3);
}

test "sysfs isDir" {
    try testing.expect(sysfs.isDir("tests/fixtures/sysfs/bus/pci/devices"));
    try testing.expect(!sysfs.isDir("tests/fixtures/sysfs/nonexistent"));
}

// PCI tests

test "pci enumerate" {
    var s = try sysfs.Sysfs.init(testing.allocator, "tests/fixtures/sysfs");
    defer s.deinit(testing.allocator);
    const devices = try pci.enumerate(testing.allocator, &s);
    defer {
        for (devices) |*dev| dev.deinit(testing.allocator);
        testing.allocator.free(devices);
    }
    try testing.expect(devices.len == 3);

    // 1. Find Intel iGPU (0000:00:02.0)
    var vga_idx: ?usize = null;
    for (devices, 0..) |dev, i| {
        if (std.mem.eql(u8, dev.id, "0000:00:02.0")) vga_idx = i;
    }
    try testing.expect(vga_idx != null);
    const vga = devices[vga_idx.?];
    try testing.expectEqualStrings("0300", vga.class_id);
    try testing.expectEqualStrings("8086", vga.vendor_id);
    try testing.expectEqualStrings("1237", vga.device_id);
    try testing.expectEqualStrings("Display controller", vga.class_name);
    try testing.expectEqualStrings("Intel Corporation", vga.vendor_name);

    // 2. Find NVIDIA dGPU (0000:01:00.0)
    var dgpu_idx: ?usize = null;
    for (devices, 0..) |dev, i| {
        if (std.mem.eql(u8, dev.id, "0000:01:00.0")) dgpu_idx = i;
    }
    try testing.expect(dgpu_idx != null);
    const dgpu = devices[dgpu_idx.?];
    try testing.expectEqualStrings("0302", dgpu.class_id);
    try testing.expectEqualStrings("10de", dgpu.vendor_id);
    try testing.expectEqualStrings("1234", dgpu.device_id);
    try testing.expectEqualStrings("Display controller", dgpu.class_name);
    try testing.expectEqualStrings("NVIDIA Corporation", dgpu.vendor_name);

    // 3. Find Realtek NIC (0000:00:1f.6)
    var nic_idx: ?usize = null;
    for (devices, 0..) |dev, i| {
        if (std.mem.eql(u8, dev.id, "0000:00:1f.6")) nic_idx = i;
    }
    try testing.expect(nic_idx != null);
    const nic = devices[nic_idx.?];
    try testing.expectEqualStrings("0200", nic.class_id);
    try testing.expectEqualStrings("10ec", nic.vendor_id);
    try testing.expectEqualStrings("8168", nic.device_id);
    try testing.expectEqualStrings("Network controller", nic.class_name);
    try testing.expectEqualStrings("Realtek Semiconductor Co., Ltd.", nic.vendor_name);
}

// USB tests

test "usb enumerate" {
    var s = try sysfs.Sysfs.init(testing.allocator, "tests/fixtures/sysfs");
    defer s.deinit(testing.allocator);
    const devices = try usb.enumerate(testing.allocator, &s);
    defer {
        for (devices) |*dev| dev.deinit(testing.allocator);
        testing.allocator.free(devices);
    }
    // Should skip "usb1" root hub, find "1-1" (Hub) and "1-2" (composite HID)
    try testing.expectEqual(@as(usize, 2), devices.len);

    var hub_idx: ?usize = null;
    var hid_idx: ?usize = null;
    for (devices, 0..) |dev, i| {
        if (std.mem.eql(u8, dev.id, "1-1")) hub_idx = i;
        if (std.mem.eql(u8, dev.id, "1-2")) hid_idx = i;
    }

    try testing.expect(hub_idx != null);
    const hub = devices[hub_idx.?];
    try testing.expectEqualStrings("09", hub.class_id);
    try testing.expectEqualStrings("046d", hub.vendor_id);
    try testing.expectEqualStrings("c52b", hub.device_id);
    try testing.expectEqualStrings("Hub", hub.class_name);
    try testing.expectEqualStrings("Logitech, Inc.", hub.vendor_name);

    try testing.expect(hid_idx != null);
    const hid = devices[hid_idx.?];
    // bDeviceClass was 00, interface 1-2:1.0 has bInterfaceClass 03 (HID)
    try testing.expectEqualStrings("03", hid.class_id);
    try testing.expectEqualStrings("046d", hid.vendor_id);
    try testing.expectEqualStrings("c077", hid.device_id);
    try testing.expectEqualStrings("Human Interface Device", hid.class_name);
    try testing.expectEqualStrings("Logitech, Inc.", hid.vendor_name);
}

// Names lookup tests

test "names pci lookup" {
    const res = try names.lookupPci(testing.allocator, "8086", "1237");
    defer testing.allocator.free(res.vendor_name);
    defer testing.allocator.free(res.device_name);
    try testing.expectEqualStrings("Intel Corporation", res.vendor_name);
    try testing.expectEqualStrings("440FX - 82441FX PMC", res.device_name);
}

test "names usb lookup" {
    const res = try names.lookupUsb(testing.allocator, "046d", "c52b");
    defer testing.allocator.free(res.vendor_name);
    defer testing.allocator.free(res.device_name);
    try testing.expectEqualStrings("Logitech, Inc.", res.vendor_name);
    try testing.expectEqualStrings("Unifying Receiver", res.device_name);
}

// Device class name tests

test "pci class names" {
    try testing.expectEqualStrings("Display controller", device.pciClassName("0300"));
    try testing.expectEqualStrings("Network controller", device.pciClassName("0200"));
    try testing.expectEqualStrings("Unknown", device.pciClassName("ff"));
}

test "usb class names" {
    try testing.expectEqualStrings("Hub", device.usbClassName("09"));
    try testing.expectEqualStrings("Human Interface Device", device.usbClassName("03"));
    try testing.expectEqualStrings("Unknown", device.usbClassName("ff"));
}

// Config parser tests

test "config parse valid string" {
    const toml =
        \\name = "video-nvidia"
        \\info = "Proprietary NVIDIA driver"
        \\version = "550.54.14"
        \\freedriver = false
        \\priority = 7
        \\conflicts = ["nvidia-390xx-utils"]
        \\depends = ["nvidia-utils", "nvidia-settings"]
        \\config_conflicts = ["video*nvidia*"]
        \\kernel_depends = ["nvidia"]
        \\kernel_conflicts = ["nvidia-390xx"]
        \\hooks_dir = "hooks"
        \\
        \\[[hardware]]
        \\class_ids = ["0300", "0302"]
        \\vendor_ids = ["10de"]
        \\device_ids = ["1234", "5678"]
        \\blacklist_device_ids = ["0000"]
    ;

    var cfg = try config.parseString(testing.allocator, toml, "", .pci);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("video-nvidia", cfg.name);
    try testing.expectEqualStrings("Proprietary NVIDIA driver", cfg.info);
    try testing.expectEqualStrings("550.54.14", cfg.version);
    try testing.expect(!cfg.freedriver);
    try testing.expectEqual(@as(i32, 7), cfg.priority);
    try testing.expectEqual(@as(usize, 1), cfg.conflicts.len);
    try testing.expectEqualStrings("nvidia-390xx-utils", cfg.conflicts[0]);
    try testing.expectEqual(@as(usize, 2), cfg.depends.len);
    try testing.expectEqual(@as(usize, 1), cfg.config_conflicts.len);
    try testing.expectEqualStrings("video*nvidia*", cfg.config_conflicts[0]);
    try testing.expectEqual(@as(usize, 1), cfg.kernel_depends.len);
    try testing.expectEqual(@as(usize, 1), cfg.kernel_conflicts.len);
    try testing.expectEqualStrings("hooks", cfg.hooks_dir);

    try testing.expectEqual(@as(usize, 1), cfg.hardware.len);
    const hw = cfg.hardware[0];
    try testing.expectEqual(@as(usize, 2), hw.class_ids.len);
    try testing.expectEqualStrings("0300", hw.class_ids[0]);
    try testing.expectEqualStrings("0302", hw.class_ids[1]);
    try testing.expectEqual(@as(usize, 1), hw.vendor_ids.len);
    try testing.expectEqualStrings("10de", hw.vendor_ids[0]);
    try testing.expectEqual(@as(usize, 2), hw.device_ids.len);
    try testing.expectEqualStrings("1234", hw.device_ids[0]);
    try testing.expectEqual(@as(usize, 1), hw.blacklist_device_ids.len);
    try testing.expectEqualStrings("0000", hw.blacklist_device_ids[0]);
}

test "config parse missing required name" {
    const toml =
        \\info = "No name driver"
        \\priority = 1
    ;
    try testing.expectError(config.ParseError.MissingName, config.parseString(testing.allocator, toml, "", .pci));
}

test "config parse bad toml" {
    const toml =
        \\name = "broken"
        \\priority = "not_an_int"
    ;
    try testing.expectError(config.ParseError.ParseError, config.parseString(testing.allocator, toml, "", .pci));
}

test "config parse missing file" {
    try testing.expectError(config.ParseError.FileNotFound, config.parseFile(testing.allocator, "nonexistent/PROBECONFIG", "", .pci));
}

test "config parse device_ids_file" {
    var cfg = try config.parseFile(testing.allocator, "tests/fixtures/test_ids/PROBECONFIG", "tests/fixtures/test_ids", .pci);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("test-ids", cfg.name);
    try testing.expectEqual(@as(usize, 1), cfg.hardware.len);
    const hw = cfg.hardware[0];
    try testing.expectEqual(@as(usize, 3), hw.device_ids.len);
    try testing.expectEqualStrings("1234", hw.device_ids[0]);
    try testing.expectEqualStrings("5678", hw.device_ids[1]);
    try testing.expectEqualStrings("abcd", hw.device_ids[2]);
}

// Matching engine tests

test "glob match patterns" {
    try testing.expect(match.globMatch("*", "anything"));
    try testing.expect(match.globMatch("video*", "video-linux"));
    try testing.expect(match.globMatch("*nvidia*", "video-nvidia-dkms"));
    try testing.expect(match.globMatch("030?", "0300"));
    try testing.expect(match.globMatch("030[0-2]", "0302"));
    try testing.expect(!match.globMatch("030[0-2]", "0303"));
    try testing.expect(match.globMatch("10DE", "10de"));
    try testing.expect(!match.globMatch("8086", "10de"));
}

fn dupeSlices(allocator: std.mem.Allocator, slices: []const []const u8) ![][]const u8 {
    const res = try allocator.alloc([]const u8, slices.len);
    for (slices, 0..) |s, i| {
        res[i] = try allocator.dupe(u8, s);
    }
    return res;
}

test "device group match and blacklist veto" {
    var hw = config.HardwareGroup{
        .class_ids = try dupeSlices(testing.allocator, &.{ "0300", "0302" }),
        .vendor_ids = try dupeSlices(testing.allocator, &.{"10de"}),
        .device_ids = try dupeSlices(testing.allocator, &.{ "1234", "5678" }),
        .blacklist_class_ids = try testing.allocator.alloc([]const u8, 0),
        .blacklist_vendor_ids = try testing.allocator.alloc([]const u8, 0),
        .blacklist_device_ids = try dupeSlices(testing.allocator, &.{"5678"}),
    };
    defer hw.deinit(testing.allocator);

    var dev1 = device.Device{
        .bus = .pci,
        .id = try testing.allocator.dupe(u8, "0000:01:00.0"),
        .class_id = try testing.allocator.dupe(u8, "0300"),
        .vendor_id = try testing.allocator.dupe(u8, "10de"),
        .device_id = try testing.allocator.dupe(u8, "1234"),
        .class_name = try testing.allocator.dupe(u8, ""),
        .vendor_name = try testing.allocator.dupe(u8, ""),
        .device_name = try testing.allocator.dupe(u8, ""),
    };
    defer dev1.deinit(testing.allocator);

    // dev1 matches
    try testing.expect(match.matchDeviceGroup(hw, dev1));

    var dev2 = device.Device{
        .bus = .pci,
        .id = try testing.allocator.dupe(u8, "0000:01:00.0"),
        .class_id = try testing.allocator.dupe(u8, "0300"),
        .vendor_id = try testing.allocator.dupe(u8, "10de"),
        .device_id = try testing.allocator.dupe(u8, "5678"), // blacklisted!
        .class_name = try testing.allocator.dupe(u8, ""),
        .vendor_name = try testing.allocator.dupe(u8, ""),
        .device_name = try testing.allocator.dupe(u8, ""),
    };
    defer dev2.deinit(testing.allocator);

    // dev2 vetoed by blacklist
    try testing.expect(!match.matchDeviceGroup(hw, dev2));
}

test "state toml save and load" {
    const tmp_path = "tests/fixtures/test_state.toml";

    var inst = [_]db.InstalledConfig{
        .{
            .name = try testing.allocator.dupe(u8, "video-linux"),
            .bus = .pci,
            .source = try testing.allocator.dupe(u8, "/usr/lib/parchprobe/db/pci/graphic_drivers/video-linux"),
            .depends = try dupeSlices(testing.allocator, &.{"xf86-video-amdgpu"}),
            .conflicts = try testing.allocator.alloc([]const u8, 0),
            .kernel_depends = try testing.allocator.alloc([]const u8, 0),
            .kernel_conflicts = try testing.allocator.alloc([]const u8, 0),
            .hooks_dir = try testing.allocator.dupe(u8, "hooks"),
        },
    };
    defer {
        for (&inst) |*c| c.deinit(testing.allocator);
    }

    try db.saveInstalled(testing.allocator, tmp_path, &inst);
    defer _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, tmp_path, 0);

    const loaded = try db.loadInstalled(testing.allocator, tmp_path, .both);
    defer {
        for (loaded) |*c| c.deinit(testing.allocator);
        testing.allocator.free(loaded);
    }

    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqualStrings("video-linux", loaded[0].name);
    try testing.expectEqual(device.Bus.pci, loaded[0].bus);
    try testing.expectEqualStrings("xf86-video-amdgpu", loaded[0].depends[0]);
}

test "db discovery and device attachment" {
    var sysfs_inst = try sysfs.Sysfs.init(testing.allocator, "tests/fixtures/sysfs");
    defer sysfs_inst.deinit(testing.allocator);

    const configs = try db.discoverConfigs(testing.allocator, &sysfs_inst, "tests/fixtures/db", .both);
    defer {
        for (configs) |*c| c.deinit(testing.allocator);
        testing.allocator.free(configs);
    }
    try testing.expectEqual(@as(usize, 3), configs.len);

    const installed = try db.loadInstalled(testing.allocator, "tests/fixtures/state.toml", .both);
    defer {
        for (installed) |*c| c.deinit(testing.allocator);
        testing.allocator.free(installed);
    }
    try testing.expectEqual(@as(usize, 1), installed.len);

    const pci_devs = try pci.enumerate(testing.allocator, &sysfs_inst);
    defer {
        for (pci_devs) |*d| d.deinit(testing.allocator);
        testing.allocator.free(pci_devs);
    }

    const attachments = try match.attachConfigs(testing.allocator, pci_devs, configs, installed);
    defer {
        for (attachments) |*att| att.deinit(testing.allocator);
        testing.allocator.free(attachments);
    }

    // Find the NVIDIA dGPU (0000:01:00.0)
    var dgpu_att: ?match.DeviceAttachment = null;
    for (attachments) |att| {
        if (std.mem.eql(u8, att.device.id, "0000:01:00.0")) {
            dgpu_att = att;
            break;
        }
    }
    try testing.expect(dgpu_att != null);
    // Should have video-nvidia (priority 7) then video-linux (priority 1)
    try testing.expectEqual(@as(usize, 2), dgpu_att.?.available.len);
    try testing.expectEqualStrings("video-nvidia", dgpu_att.?.available[0]);
    try testing.expectEqualStrings("video-linux", dgpu_att.?.available[1]);
    try testing.expectEqual(@as(usize, 1), dgpu_att.?.installed.len);
    try testing.expectEqualStrings("video-linux", dgpu_att.?.installed[0]);
}





test "alpm handle initialization" {
    const alpm_lib = @import("alpm");
    var handle = try alpm_lib.Handle.init(testing.allocator, "/", "/var/lib/pacman");
    defer handle.deinit();
    const local_db = handle.getLocalDb();
    _ = local_db.getName();
}

test "alpm query local packages and kernels" {
    const alpm_lib = @import("alpm");
    var handle = try alpm_lib.Handle.init(testing.allocator, "/", "/var/lib/pacman");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkg_cache = local_db.getPackageCache();
    var it = pkg_cache.iterator();
    var count: usize = 0;
    while (it.next()) |pkg| {
        count += 1;
        const name = pkg.getName();
        if (std.mem.startsWith(u8, name, "linux")) {
            // Found a linux package
        }
    }
    try testing.expect(count > 0);
}

test "alpm handle in temporary directory sandbox" {
    const alpm_lib = @import("alpm");
    const test_dir = "/tmp/parchprobe_alpm_test_sandbox";
    _ = std.os.linux.mkdir(test_dir, 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_alpm_test_sandbox/var", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_alpm_test_sandbox/var/lib", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_alpm_test_sandbox/var/lib/pacman", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_alpm_test_sandbox/var/lib/pacman/local", 0o755);

    var handle = try alpm_lib.Handle.init(testing.allocator, test_dir, "/tmp/parchprobe_alpm_test_sandbox/var/lib/pacman");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    try testing.expectEqualStrings("local", local_db.getName());
    const pkg_cache = local_db.getPackageCache();
    try testing.expectEqual(@as(usize, 0), pkg_cache.count());
}

test "pacman isKernelPkg" {
    try testing.expect(pacman.Pacman.isKernelPkg("linux66"));
    try testing.expect(pacman.Pacman.isKernelPkg("linux612"));
    try testing.expect(pacman.Pacman.isKernelPkg("linux61"));
    try testing.expect(!pacman.Pacman.isKernelPkg("linux"));
    try testing.expect(!pacman.Pacman.isKernelPkg("linux-headers"));
    try testing.expect(!pacman.Pacman.isKernelPkg("linux-lts"));
    try testing.expect(!pacman.Pacman.isKernelPkg("linux-zen"));
    try testing.expect(!pacman.Pacman.isKernelPkg("util-linux"));
}

test "pacman buildPacmanArgv" {
    const opts = pacman.PacmanOptions{
        .pm_root = "/mnt/target",
        .pm_config = "/etc/custom-pacman.conf",
        .pm_cache_dir = "/var/cache/custom",
    };
    const op_flags = [_][]const u8{ "-S", "--needed" };
    const targets = [_][]const u8{ "nvidia-utils", "nvidia-settings" };

    const argv = try pacman.Pacman.buildPacmanArgv(testing.allocator, opts, &op_flags, &targets);
    defer testing.allocator.free(argv);

    try testing.expectEqualStrings("pacman", argv[0]);
    try testing.expectEqualStrings("--noconfirm", argv[1]);
    try testing.expectEqualStrings("-S", argv[2]);
    try testing.expectEqualStrings("--needed", argv[3]);
    try testing.expectEqualStrings("--root", argv[4]);
    try testing.expectEqualStrings("/mnt/target", argv[5]);
    try testing.expectEqualStrings("--config", argv[6]);
    try testing.expectEqualStrings("/etc/custom-pacman.conf", argv[7]);
    try testing.expectEqualStrings("--cachedir", argv[8]);
    try testing.expectEqualStrings("/var/cache/custom", argv[9]);
    try testing.expectEqualStrings("nvidia-utils", argv[10]);
    try testing.expectEqualStrings("nvidia-settings", argv[11]);
}

test "hooks normalizeBusId" {
    try testing.expectEqualStrings("01:00.0", hooks.normalizeBusId(.pci, "0000:01:00.0"));
    try testing.expectEqualStrings("00:02.0", hooks.normalizeBusId(.pci, "0000:00:02.0"));
    try testing.expectEqualStrings("01:00.0", hooks.normalizeBusId(.pci, "01:00.0"));
    try testing.expectEqualStrings("1-2", hooks.normalizeBusId(.usb, "1-2"));
    try testing.expectEqualStrings("1-4.1", hooks.normalizeBusId(.usb, "1-4.1"));
}

test "hooks execution" {
    const hook_dir = "/tmp/parchprobe_test_hooks";
    _ = std.os.linux.mkdir(hook_dir, 0o755);

    const script_file = "/tmp/parchprobe_test_hooks/pre-install";
    const script_content =
        "#!/bin/sh\n" ++
        "echo \"$PARCHPROBE_OPERATION $1 $2 $3 $4\" > /tmp/parchprobe_test_hooks/output.txt\n" ++
        "exit 0\n";

    const fd = try std.posix.openat(std.posix.AT.FDCWD, script_file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    _ = std.os.linux.write(fd, script_content.ptr, script_content.len);
    _ = std.os.linux.close(fd);

    const test_dev = device.Device{
        .bus = .pci,
        .id = "0000:01:00.0",
        .class_id = "0300",
        .vendor_id = "10de",
        .device_id = "1c03",
        .class_name = "VGA",
        .vendor_name = "NVIDIA",
        .device_name = "GP106",
    };

    try hooks.runHook(
        testing.allocator,
        testing.io,
        hook_dir,
        "",
        .pre_install,
        &.{test_dev},
    );

    // Verify output file
    const out_fd = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_test_hooks/output.txt", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(out_fd);

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(out_fd, &buf);
    const content = std.mem.trim(u8, buf[0..n], " \t\r\n");

    try testing.expectEqualStrings("install 0300 10de 1c03 01:00.0", content);
}

test "hooks failure aborts" {
    const hook_dir = "/tmp/parchprobe_test_hooks_fail";
    _ = std.os.linux.mkdir(hook_dir, 0o755);

    const script_file = "/tmp/parchprobe_test_hooks_fail/pre-install";
    const script_content =
        "#!/bin/sh\n" ++
        "exit 1\n";

    const fd = try std.posix.openat(std.posix.AT.FDCWD, script_file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    _ = std.os.linux.write(fd, script_content.ptr, script_content.len);
    _ = std.os.linux.close(fd);

    const test_dev = device.Device{
        .bus = .pci,
        .id = "0000:01:00.0",
        .class_id = "0300",
        .vendor_id = "10de",
        .device_id = "1c03",
        .class_name = "VGA",
        .vendor_name = "NVIDIA",
        .device_name = "GP106",
    };

    const result = hooks.runHook(
        testing.allocator,
        testing.io,
        hook_dir,
        "",
        .pre_install,
        &.{test_dev},
    );

    try testing.expectError(error.HookFailed, result);
}

test "tx checkRoot" {
    // dry_run allows non-root
    try tx.checkRoot(.{ .dry_run = true });
    // allow_non_root allows non-root
    try tx.checkRoot(.{ .allow_non_root = true });
}

test "tx install, conflict detection, remove, and auto in sandbox" {
    const sandbox_dir = "/tmp/parchprobe_tx_test_sandbox";
    _ = std.os.linux.mkdir(sandbox_dir, 0o755);

    // Setup sysfs fixture
    const sysfs_dir = "/tmp/parchprobe_tx_test_sandbox/sys";
    _ = std.os.linux.mkdir(sysfs_dir, 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/sys/bus", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/sys/bus/pci", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/sys/bus/pci/devices", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/sys/bus/pci/devices/0000:01:00.0", 0o755);

    var f = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_tx_test_sandbox/sys/bus/pci/devices/0000:01:00.0/class", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = std.os.linux.write(f, "0x030000\n", 9);
    _ = std.os.linux.close(f);

    f = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_tx_test_sandbox/sys/bus/pci/devices/0000:01:00.0/vendor", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = std.os.linux.write(f, "0x10de\n", 7);
    _ = std.os.linux.close(f);

    f = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_tx_test_sandbox/sys/bus/pci/devices/0000:01:00.0/device", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = std.os.linux.write(f, "0x1c03\n", 7);
    _ = std.os.linux.close(f);

    // Setup DB fixture
    const db_dir = "/tmp/parchprobe_tx_test_sandbox/db";
    _ = std.os.linux.mkdir(db_dir, 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/db/pci", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/db/pci/graphic_drivers", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/db/pci/graphic_drivers/video-linux", 0o755);
    _ = std.os.linux.mkdir("/tmp/parchprobe_tx_test_sandbox/db/pci/graphic_drivers/video-nvidia", 0o755);

    const vlinux_content =
        "name = \"video-linux\"\n" ++
        "info = \"Open-source driver\"\n" ++
        "freedriver = true\n" ++
        "priority = 1\n" ++
        "[[hardware]]\n" ++
        "class_ids = [\"0300\"]\n" ++
        "vendor_ids = [\"*\"]\n" ++
        "device_ids = [\"*\"]\n" ++
        "depends = [\"xf86-video-nouveau\"]\n" ++
        "conflicts = [\"nvidia-utils\"]\n" ++
        "config_conflicts = [\"video-nvidia*\"]\n";

    f = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_tx_test_sandbox/db/pci/graphic_drivers/video-linux/PROBECONFIG", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = std.os.linux.write(f, vlinux_content.ptr, vlinux_content.len);
    _ = std.os.linux.close(f);

    const vnvidia_content =
        "name = \"video-nvidia\"\n" ++
        "info = \"Proprietary driver\"\n" ++
        "freedriver = false\n" ++
        "priority = 7\n" ++
        "[[hardware]]\n" ++
        "class_ids = [\"0300\"]\n" ++
        "vendor_ids = [\"10de\"]\n" ++
        "device_ids = [\"*\"]\n" ++
        "depends = [\"nvidia-utils\"]\n" ++
        "conflicts = [\"xf86-video-nouveau\"]\n" ++
        "config_conflicts = [\"video-linux*\"]\n";

    f = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/parchprobe_tx_test_sandbox/db/pci/graphic_drivers/video-nvidia/PROBECONFIG", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = std.os.linux.write(f, vnvidia_content.ptr, vnvidia_content.len);
    _ = std.os.linux.close(f);

    // Setup state file
    const state_path = "/tmp/parchprobe_tx_test_sandbox/state.toml";
    // Initialize empty state
    _ = std.os.linux.unlink(state_path);

    // Env setup
    var sysfs_inst = try sysfs.Sysfs.init(testing.allocator, sysfs_dir);
    defer sysfs_inst.deinit(testing.allocator);

    // Set env vars so db functions pick them up
    // Note: getDbRoot checks PARCHPROBE_DB, getStateFilePath checks PARCHPROBE_STATE
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    // Since our test process reads env via getEnvVar (/proc/self/environ),
    // let's test db.discoverConfigs directly with db_dir
    const discovered = try db.discoverConfigs(testing.allocator, &sysfs_inst, db_dir, .pci);
    defer {
        for (discovered) |*c| c.deinit(testing.allocator);
        testing.allocator.free(discovered);
    }
    try testing.expectEqual(@as(usize, 2), discovered.len);

    // Check conflict matching between config_conflicts and installed names
    try testing.expect(match.globMatch("video-nvidia*", "video-nvidia"));
    try testing.expect(match.globMatch("video-linux*", "video-linux"));
    try testing.expect(!match.globMatch("video-nvidia*", "network-broadcom"));

    const tx_opts = tx.TransactionOptions{
        .allow_non_root = true,
        .skip_pkg_ops = true,
        .db_root = db_dir,
        .state_file = state_path,
    };

    // 1. Install video-linux
    try tx.installConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-linux"}, tx_opts);

    // Verify state.toml has video-linux
    const inst1 = try db.loadInstalled(testing.allocator, state_path, .pci);
    defer {
        for (inst1) |*c| c.deinit(testing.allocator);
        testing.allocator.free(inst1);
    }
    try testing.expectEqual(@as(usize, 1), inst1.len);
    try testing.expectEqualStrings("video-linux", inst1[0].name);

    // 2. Try installing video-nvidia -> blocked by config_conflicts ("video-linux*")
    const conflict_res = tx.installConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-nvidia"}, tx_opts);
    try testing.expectError(error.ConfigConflict, conflict_res);

    // 3. Remove video-linux
    try tx.removeConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-linux"}, tx_opts);

    // Verify state.toml is empty
    const inst2 = try db.loadInstalled(testing.allocator, state_path, .pci);
    defer {
        for (inst2) |*c| c.deinit(testing.allocator);
        testing.allocator.free(inst2);
    }
    try testing.expectEqual(@as(usize, 0), inst2.len);

    // 4. Install video-nvidia
    try tx.installConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-nvidia"}, tx_opts);

    const inst3 = try db.loadInstalled(testing.allocator, state_path, .pci);
    defer {
        for (inst3) |*c| c.deinit(testing.allocator);
        testing.allocator.free(inst3);
    }
    try testing.expectEqual(@as(usize, 1), inst3.len);
    try testing.expectEqualStrings("video-nvidia", inst3[0].name);

    // 5. Try installing video-nvidia again without --force -> AlreadyInstalled error
    const re_res = tx.installConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-nvidia"}, tx_opts);
    try testing.expectError(error.AlreadyInstalled, re_res);

    // 6. Remove video-nvidia
    try tx.removeConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-nvidia"}, tx_opts);

    // 7. Test auto free: should pick video-linux (freedriver=true)
    try tx.autoInstall(testing.allocator, testing.io, &sysfs_inst, .pci, "free", "0300", tx_opts);

    const inst4 = try db.loadInstalled(testing.allocator, state_path, .pci);
    defer {
        for (inst4) |*c| c.deinit(testing.allocator);
        testing.allocator.free(inst4);
    }
    try testing.expectEqual(@as(usize, 1), inst4.len);
    try testing.expectEqualStrings("video-linux", inst4[0].name);

    // 8. Remove video-linux
    try tx.removeConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-linux"}, tx_opts);

    // 9. Test auto nonfree: should pick video-nvidia (priority 7 > priority 1)
    try tx.autoInstall(testing.allocator, testing.io, &sysfs_inst, .pci, "nonfree", "0300", tx_opts);

    const inst5 = try db.loadInstalled(testing.allocator, state_path, .pci);
    defer {
        for (inst5) |*c| c.deinit(testing.allocator);
        testing.allocator.free(inst5);
    }
    try testing.expectEqual(@as(usize, 1), inst5.len);
    try testing.expectEqualStrings("video-nvidia", inst5[0].name);

    // Cleanup final installed
    try tx.removeConfigs(testing.allocator, testing.io, &sysfs_inst, .pci, &.{"video-nvidia"}, tx_opts);
}

test "production db discovery and validation" {
    var sysfs_inst = try sysfs.Sysfs.initFromEnv(testing.allocator);
    defer sysfs_inst.deinit(testing.allocator);

    const configs = try db.discoverConfigs(testing.allocator, &sysfs_inst, "db", .both);
    defer {
        for (configs) |*c| c.deinit(testing.allocator);
        testing.allocator.free(configs);
    }

    try testing.expect(configs.len >= 7);

    var has_nvidia = false;
    var has_video_linux = false;
    var has_r8168 = false;
    var has_broadcom = false;

    for (configs) |c| {
        if (std.mem.eql(u8, c.name, "video-nvidia")) {
            has_nvidia = true;
            try testing.expect(!c.freedriver);
            try testing.expectEqual(@as(i32, 7), c.priority);
        } else if (std.mem.eql(u8, c.name, "video-linux")) {
            has_video_linux = true;
            try testing.expect(c.freedriver);
        } else if (std.mem.eql(u8, c.name, "network-r8168")) {
            has_r8168 = true;
            try testing.expect(c.freedriver);
        } else if (std.mem.eql(u8, c.name, "network-broadcom-wl")) {
            has_broadcom = true;
            try testing.expect(!c.freedriver);
        }
    }

    try testing.expect(has_nvidia);
    try testing.expect(has_video_linux);
    try testing.expect(has_r8168);
    try testing.expect(has_broadcom);
}


