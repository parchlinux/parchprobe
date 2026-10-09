const std = @import("std");
const alpm = @import("alpm");
const cli = @import("../cli.zig");

pub const PacmanOptions = struct {
    pm_root: []const u8 = "",
    pm_config: []const u8 = "",
    pm_cache_dir: []const u8 = "",
};

/// High-level package manager operations backed by ALPM (via alpm-zig)
/// and system pacman.
pub const Pacman = struct {
    allocator: std.mem.Allocator,
    options: PacmanOptions,
    handle: ?alpm.Handle = null,
    root_path: []const u8,
    db_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, options: PacmanOptions) !Pacman {
        const root = if (options.pm_root.len > 0) options.pm_root else "/";
        const dbpath = if (options.pm_root.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/var/lib/pacman", .{options.pm_root})
        else
            try allocator.dupe(u8, "/var/lib/pacman");
        errdefer allocator.free(dbpath);

        const root_z = try allocator.dupeZ(u8, root);
        defer allocator.free(root_z);
        const dbpath_z = try allocator.dupeZ(u8, dbpath);
        defer allocator.free(dbpath_z);

        var self = Pacman{
            .allocator = allocator,
            .options = options,
            .handle = null,
            .root_path = try allocator.dupe(u8, root),
            .db_path = dbpath,
        };

        if (alpm.Handle.init(allocator, root_z, dbpath_z)) |h| {
            self.handle = h;
            if (options.pm_cache_dir.len > 0) {
                const cache_z = allocator.dupeZ(u8, options.pm_cache_dir) catch null;
                if (cache_z) |cz| {
                    defer allocator.free(cz);
                    if (alpm.StringList.fromSlice(allocator, &.{cz})) |list| {
                        self.handle.?.setCacheDirs(list) catch {};
                    } else |_| {}
                }
            }
        } else |_| {
            // If ALPM init fails (e.g. non-existent DB path in dry-run or mock), handle remains null
        }

        return self;
    }

    pub fn deinit(self: *Pacman) void {
        if (self.handle) |*h| {
            h.deinit();
            self.handle = null;
        }
        self.allocator.free(self.root_path);
        self.allocator.free(self.db_path);
    }

    /// Checks if a package name matches the installed kernel pattern (^linux[0-9]+$).
    pub fn isKernelPkg(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, "linux")) return false;
        const num_part = name[5..];
        if (num_part.len == 0) return false;
        for (num_part) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }

    /// Checks if a package is installed in the local database.
    pub fn isPackageInstalled(self: *Pacman, name: []const u8) bool {
        if (self.handle) |*h| {
            const name_z = self.allocator.dupeZ(u8, name) catch return false;
            defer self.allocator.free(name_z);
            const local_db = h.getLocalDb();
            return local_db.getPackage(name_z) != null;
        }
        return false;
    }

    /// Collects names of all currently installed packages from local ALPM DB.
    pub fn getInstalledPackages(self: *Pacman, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }

        if (self.handle) |*h| {
            const local_db = h.getLocalDb();
            const pkg_cache = local_db.getPackageCache();
            var it = pkg_cache.iterator();
            while (it.next()) |pkg| {
                const name = pkg.getName();
                try list.append(allocator, try allocator.dupe(u8, name));
            }
        }

        return list.toOwnedSlice(allocator);
    }

    /// Finds all installed kernels matching ^linux[0-9]+$.
    pub fn getInstalledKernels(self: *Pacman, allocator: std.mem.Allocator) ![][]const u8 {
        var kernels = std.ArrayList([]const u8).empty;
        errdefer {
            for (kernels.items) |s| allocator.free(s);
            kernels.deinit(allocator);
        }

        if (self.handle) |*h| {
            const local_db = h.getLocalDb();
            const pkg_cache = local_db.getPackageCache();
            var it = pkg_cache.iterator();
            while (it.next()) |pkg| {
                const name = pkg.getName();
                if (isKernelPkg(name)) {
                    try kernels.append(allocator, try allocator.dupe(u8, name));
                }
            }
        }

        return kernels.toOwnedSlice(allocator);
    }

    /// Expands kernel prefixes (e.g. ["nvidia"]) against all installed kernels
    /// into full package names (e.g. ["linux66-nvidia"]).
    pub fn expandKernelPackages(
        self: *Pacman,
        allocator: std.mem.Allocator,
        prefixes: []const []const u8,
    ) ![][]const u8 {
        if (prefixes.len == 0) return try allocator.alloc([]const u8, 0);

        const kernels = try self.getInstalledKernels(allocator);
        defer {
            for (kernels) |k| allocator.free(k);
            allocator.free(kernels);
        }

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        for (kernels) |kernel| {
            for (prefixes) |prefix| {
                const pkg = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ kernel, prefix });
                try result.append(allocator, pkg);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Filters a list of packages to only those currently installed.
    pub fn filterInstalled(
        self: *Pacman,
        allocator: std.mem.Allocator,
        pkgs: []const []const u8,
    ) ![][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        for (pkgs) |pkg| {
            if (self.isPackageInstalled(pkg)) {
                try result.append(allocator, try allocator.dupe(u8, pkg));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Builds command-line argument list for pacman operations.
    pub fn buildPacmanArgv(
        allocator: std.mem.Allocator,
        options: PacmanOptions,
        op_args: []const []const u8,
        targets: []const []const u8,
    ) ![][]const u8 {
        var argv = std.ArrayList([]const u8).empty;
        errdefer argv.deinit(allocator);

        try argv.append(allocator, "pacman");
        try argv.append(allocator, "--noconfirm");

        for (op_args) |arg| {
            try argv.append(allocator, arg);
        }

        if (options.pm_root.len > 0) {
            try argv.append(allocator, "--root");
            try argv.append(allocator, options.pm_root);
        }
        if (options.pm_config.len > 0) {
            try argv.append(allocator, "--config");
            try argv.append(allocator, options.pm_config);
        }
        if (options.pm_cache_dir.len > 0) {
            try argv.append(allocator, "--cachedir");
            try argv.append(allocator, options.pm_cache_dir);
        }

        for (targets) |t| {
            try argv.append(allocator, t);
        }

        return argv.toOwnedSlice(allocator);
    }

    /// Installs packages using pacman with --needed, followed by marking as explicit.
    pub fn executeInstall(
        self: *Pacman,
        allocator: std.mem.Allocator,
        io: std.Io,
        pkgs: []const []const u8,
        sync_refresh: bool,
    ) !void {
        if (pkgs.len == 0) return;

        var op_flags: [2][]const u8 = undefined;
        var op_len: usize = 0;
        if (sync_refresh) {
            op_flags[op_len] = "-Sy";
            op_len += 1;
        } else {
            op_flags[op_len] = "-S";
            op_len += 1;
        }
        op_flags[op_len] = "--needed";
        op_len += 1;

        const install_argv = try buildPacmanArgv(allocator, self.options, op_flags[0..op_len], pkgs);
        defer allocator.free(install_argv);

        const res = std.process.run(allocator, io, .{
            .argv = install_argv,
        }) catch return error.PacmanExecutionFailed;
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }

        if (res.term != .exited or res.term.exited != 0) {
            return error.PacmanInstallFailed;
        }

        // Mark installed packages explicit (-D --asexplicit)
        const explicit_flags = [_][]const u8{ "-D", "--asexplicit" };
        const explicit_argv = try buildPacmanArgv(allocator, self.options, &explicit_flags, pkgs);
        defer allocator.free(explicit_argv);

        const exp_res = std.process.run(allocator, io, .{
            .argv = explicit_argv,
        }) catch return error.PacmanExecutionFailed;
        defer {
            allocator.free(exp_res.stdout);
            allocator.free(exp_res.stderr);
        }

        if (exp_res.term != .exited or exp_res.term.exited != 0) {
            return error.PacmanMarkExplicitFailed;
        }
    }

    /// Removes packages using pacman -Rs.
    pub fn executeRemove(
        self: *Pacman,
        allocator: std.mem.Allocator,
        io: std.Io,
        pkgs: []const []const u8,
    ) !void {
        if (pkgs.len == 0) return;

        const remove_flags = [_][]const u8{"-Rs"};
        const remove_argv = try buildPacmanArgv(allocator, self.options, &remove_flags, pkgs);
        defer allocator.free(remove_argv);

        const res = std.process.run(allocator, io, .{
            .argv = remove_argv,
        }) catch return error.PacmanExecutionFailed;
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }

        if (res.term != .exited or res.term.exited != 0) {
            return error.PacmanRemoveFailed;
        }
    }
};
