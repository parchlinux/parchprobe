ptr: *c.alpm_handle_t,
arena: *std.heap.ArenaAllocator,
progress: std.Progress.Node,
blocking_op: std.Progress.Node,
run_hook_op: std.Progress.Node,
install_map: std.StringHashMap(std.Progress.Node),
reinstall_map: std.StringHashMap(std.Progress.Node),
upgrade_map: std.StringHashMap(std.Progress.Node),
downgrade_map: std.StringHashMap(std.Progress.Node),
remove_map: std.StringHashMap(std.Progress.Node),

/// Initializes the libalpm handle. This must be called before any other function.
/// Creates the handle, connects to the database, and creates a lockfile.
///
/// - `allocator`: The allocator for the Handle struct and its internal arena.
/// - `root`: The root path for all filesystem operations.
/// - `dbpath`: The absolute path to the libalpm database.
pub fn init(
    allocator: std.mem.Allocator,
    root: [*:0]const u8,
    dbpath: [*:0]const u8,
) !Handle {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);

    var err: c.alpm_errno_t = 0;
    const handle_ptr = c.alpm_initialize(root, dbpath, &err);
    if (handle_ptr == null) {
        @branchHint(.unlikely);
        return alpm.errnoToError(err);
    }

    return .{
        .install_map = .init(allocator),
        .reinstall_map = .init(allocator),
        .upgrade_map = .init(allocator),
        .downgrade_map = .init(allocator),
        .remove_map = .init(allocator),
        .blocking_op = .none,
        .run_hook_op = .none,
        .progress = .none,
        .arena = arena,
        .ptr = handle_ptr.?,
    };
}

/// Releases the libalpm handle and all associated resources.
/// Disconnects from the database, removes the handle and lockfile.
/// This should be the last alpm call made. The handle is invalid after this call.
pub fn deinit(self: *Handle) void {
    self.progress.end();
    const gpa = self.arena.child_allocator;
    _ = c.alpm_release(self.ptr);
    self.install_map.deinit();
    self.reinstall_map.deinit();
    self.upgrade_map.deinit();
    self.downgrade_map.deinit();
    self.remove_map.deinit();
    self.arena.deinit();
    gpa.destroy(self.arena);
}

/// Returns the current error code from the handle.
pub fn getErrno(self: *const Handle) alpm.Error {
    return alpm.errnoToError(c.alpm_errno(self.ptr));
}

/// Gets the list of registered sync databases.
/// The returned List and its Databases are owned by the Handle and are valid
/// until the handle is deinitialized.
pub fn getSyncDbs(self: *const Handle) Database.List {
    return .fromList(c.alpm_get_syncdbs(self.ptr));
}

/// Gets the database of locally installed packages.
/// The returned Database is owned by the Handle and is valid
/// until the handle is deinitialized.
pub fn getLocalDb(self: *const Handle) Database {
    return .{ .ptr = (c.alpm_get_localdb(self.ptr)).? };
}

/// Registers a sync database. Databases cannot be registered during an active transaction.
///
/// - `treename`: The name of the sync repository (e.g., "core").
/// - `level`: The signature verification level for the database.
///
/// Returns a pointer to the newly registered database, which is owned by the Handle.
pub fn registerSyncDb(self: *Handle, treename: [*:0]const u8, level: SigLevel) !Database {
    const db_ptr = c.alpm_register_syncdb(self.ptr, treename, @bitCast(level));
    if (db_ptr == null) {
        return self.getErrno();
    }
    return .{ .ptr = db_ptr.? };
}

/// Unregisters all sync databases. Cannot be called during an active transaction.
pub fn unregisterAllSyncDbs(self: *Handle) !void {
    if (c.alpm_unregister_all_syncdbs(self.ptr) != 0) {
        return self.getErrno();
    }
}

/// Updates the specified package databases.
///
/// - `dbs`: A list of databases to update.
/// - `force`: If true, forces the update even if databases appear up-to-date.
///
/// Returns `true` if an update was performed, `false` if all databases were already up-to-date.
pub fn dbUpdate(self: *Handle, dbs: Database.List, force: bool) !bool {
    const res = c.alpm_db_update(self.ptr, dbs.child.list, @intFromBool(force));
    if (res < 0) {
        return self.getErrno();
    }
    return res == 0;
}

// --- Option Accessors ---

/// Sets the logging callback.
pub fn setLogCallback(self: *Handle, cb: c.alpm_cb_log, ctx: ?*anyopaque) void {
    _ = c.alpm_option_set_logcb(self.ptr, cb, ctx);
}

/// Sets the download callback.
pub fn setDownloadCallback(self: *Handle) void {
    _ = c.alpm_option_set_dlcb(self.ptr, downloadCallback, self);
}

/// Sets the fetch callback.
pub fn setFetchCallback(self: *Handle) void {
    _ = c.alpm_option_set_fetchcb(self.ptr, fetchCallback, self);
}

/// Sets the event callback.
pub fn setEventCallback(self: *Handle) void {
    _ = c.alpm_option_set_eventcb(self.ptr, eventCallback, self);
}

/// Sets the question callback.
pub fn setQuestionCallback(self: *Handle) void {
    _ = c.alpm_option_set_questioncb(self.ptr, questionCallback, null);
}

/// Sets the progress callback.
pub fn setProgressCallback(self: *Handle) void {
    _ = c.alpm_option_set_progresscb(self.ptr, progressCallback, self);
}

/// Returns the root path. The slice is valid for the lifetime of the Handle.
pub fn getRoot(self: *const Handle) []const u8 {
    return std.mem.sliceTo(c.alpm_option_get_root(self.ptr), 0);
}

/// Returns the database path. The slice is valid for the lifetime of the Handle.
pub fn getDbPath(self: *const Handle) []const u8 {
    return std.mem.sliceTo(c.alpm_option_get_dbpath(self.ptr), 0);
}

/// Gets the list of package cache directories.
/// The returned List and its string slices are owned by the Handle.
pub fn getCacheDirs(self: *const Handle) alpm.StringList {
    return .{ .list = (c.alpm_option_get_cachedirs(self.ptr)) };
}

/// Sets the list of package cache directories. The provided list is duplicated.
pub fn setCacheDirs(self: *Handle, cachedirs: alpm.StringList) !void {
    if (c.alpm_option_set_cachedirs(self.ptr, cachedirs.list) != 0) {
        return self.getErrno();
    }
}

/// Appends a directory to the list of package cache directories.
pub fn addCacheDir(self: *Handle, cachedir: [*:0]const u8) !void {
    if (c.alpm_option_add_cachedir(self.ptr, cachedir) != 0) {
        return self.getErrno();
    }
}

/// Gets the list of hook directories.
/// The returned List and its string slices are owned by the Handle.
pub fn getHookDirs(self: *const Handle) alpm.StringList {
    return .{ .list = (c.alpm_option_get_hookdirs(self.ptr)) };
}

/// Sets the list of hook directories. The provided list is duplicated.
pub fn setHookDirs(self: *Handle, hookdirs: alpm.StringList) !void {
    if (c.alpm_option_set_hookdirs(self.ptr, hookdirs.list) != 0) {
        return self.getErrno();
    }
}

pub fn setDisableSandbox(self: *Handle, disable_sandbox: bool) !void {
    if (c.alpm_option_set_disable_sandbox(self.ptr, @intFromBool(disable_sandbox)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets the log file path.
pub fn setLogFile(self: *Handle, logfile: [*:0]const u8) !void {
    if (c.alpm_option_set_logfile(self.ptr, logfile) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets the GPG directory path.
pub fn setGpgDir(self: *Handle, gpgdir: [*:0]const u8) !void {
    if (c.alpm_option_set_gpgdir(self.ptr, gpgdir) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Gets the GPG directory path. The slice is valid for the lifetime of the Handle.
pub fn getGpgDir(self: *const Handle) []const u8 {
    return std.mem.sliceTo(c.alpm_option_get_gpgdir(self.ptr), 0);
}

pub fn setParallelDownload(self: *const Handle, num_streams: usize) void {
    _ = c.alpm_option_set_parallel_downloads(self.ptr, @intCast(num_streams));
}

/// Gets the list of ignored packages.
/// The returned List and its string slices are owned by the Handle.
pub fn getIgnorePkgs(self: *const Handle) alpm.StringList {
    return .{ .list = (c.alpm_option_get_ignorepkgs(self.ptr)) };
}

/// Adds a package to the ignore list.
pub fn addIgnorePkg(self: *Handle, pkg: [*:0]const u8) !void {
    if (c.alpm_option_add_ignorepkg(self.ptr, pkg) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Gets the list of ignored groups.
/// The returned List and its string slices are owned by the Handle.
pub fn getIgnoreGroups(self: *const Handle) alpm.StringList {
    return .{ .list = c.alpm_option_get_ignoregroups(self.ptr) };
}

/// Adds a group to the ignore list.
pub fn addIgnoreGroup(self: *Handle, group: [*:0]const u8) !void {
    if (c.alpm_option_add_ignoregroup(self.ptr, group) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets the default signature verification level.
pub fn setDefaultSigLevel(self: *Handle, level: SigLevel) !void {
    if (c.alpm_option_set_default_siglevel(self.ptr, @bitCast(level)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets the signature verification level for local package files.
pub fn setLocalFileSigLevel(self: *Handle, level: SigLevel) !void {
    if (c.alpm_option_set_local_file_siglevel(self.ptr, @bitCast(level)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets the signature verification level for remote package files.
pub fn setRemoteFileSigLevel(self: *Handle, level: SigLevel) !void {
    if (c.alpm_option_set_remote_file_siglevel(self.ptr, @bitCast(level)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

// --- Transaction Functions ---

/// Initializes a transaction.
pub fn transactionInit(self: *Handle, flags: alpm.TransactionFlags) !void {
    if (c.alpm_trans_init(self.ptr, @bitCast(flags)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Prepares a transaction, checking for dependencies and conflicts.
/// Returns a list of missing dependencies on failure. The caller must free this list.
pub fn transactionPrepare(self: *Handle) !void {
    var missing: ?*c.alpm_list_t = null;
    defer c.alpm_list_free(missing);
    if (c.alpm_trans_prepare(self.ptr, &missing) != 0) {
        @branchHint(.unlikely);
        // TODO: Wrap and return `missing` list idiomatically.
        // For now, just indicate failure.
        return self.getErrno();
    }
}

/// Commits a transaction, applying changes to the system.
/// Returns a list of file conflicts on failure. The caller must free this list.
pub fn transactionCommit(self: *Handle) !void {
    var conflicts: ?*c.alpm_list_t = null;
    defer c.alpm_list_free(conflicts);
    if (c.alpm_trans_commit(self.ptr, &conflicts) != 0) {
        @branchHint(.unlikely);
        // TODO: Wrap and return `conflicts` list idiomatically.
        return self.getErrno();
    }
}

/// Releases a transaction, cleaning up any resources.
pub fn transactionRelease(self: *Handle) void {
    if (c.alpm_trans_release(self.ptr) != 0) {
        @branchHint(.unlikely);
        log.err("Failed to release transaction: {t}", .{self.getErrno()});
        return;
    }
}

/// Adds a package for installation/upgrade to the current transaction.
/// The package will be freed automatically when the transaction is released.
pub fn addPackage(self: *Handle, pkg: Package) !void {
    if (c.alpm_add_pkg(self.ptr, pkg.ptr) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Adds a package for removal to the current transaction.
pub fn removePackage(self: *Handle, pkg: Package) !void {
    if (c.alpm_remove_pkg(self.ptr, pkg.ptr) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Searches for packages to upgrade and adds them to the transaction.
///
/// - `enable_downgrade`: If true, allows downgrading packages if the remote version is lower.
pub fn syncSysupgrade(self: *Handle, enable_downgrade: bool) !void {
    if (c.alpm_sync_sysupgrade(self.ptr, @intFromBool(enable_downgrade)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Loads a package from a file on disk.
///
/// - `filename`: Path to the package file.
/// - `full_load`: If true, reads the entire archive to verify integrity and load file lists.
/// - `level`: The signature verification level to apply to this package.
///
/// The returned Package is owned by the caller and must be freed with `Package.free()`.
pub fn loadPackage(
    self: *Handle,
    filename: [*:0]const u8,
    full_load: bool,
    level: SigLevel,
) !Package {
    var pkg_ptr: ?*c.alpm_pkg_t = null;
    if (c.alpm_pkg_load(self.ptr, filename, @intFromBool(full_load), @bitCast(level), &pkg_ptr) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
    return .{ .ptr = pkg_ptr.? };
}

/// Removes a directory from the list of package cache directories.
pub fn removeCacheDir(self: *Handle, cachedir: [*:0]const u8) !void {
    if (c.alpm_option_remove_cachedir(self.ptr, cachedir) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Appends a directory to the list of hook directories.
pub fn addHookDir(self: *Handle, hookdir: [*:0]const u8) !void {
    if (c.alpm_option_add_hookdir(self.ptr, hookdir) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Removes a directory from the list of hook directories.
pub fn removeHookDir(self: *Handle, hookdir: [*:0]const u8) !void {
    if (c.alpm_option_remove_hookdir(self.ptr, hookdir) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Sets whether to check for available disk space before transactions.
pub fn setCheckSpace(self: *Handle, check: bool) !void {
    if (c.alpm_option_set_checkspace(self.ptr, @intFromBool(check)) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Adds an architecture to the list of allowed architectures.
pub fn addArchitecture(self: *Handle, arch: [*:0]const u8) !void {
    if (c.alpm_option_add_architecture(self.ptr, arch) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

/// Finds a package that satisfies a dependency string within a list of sync databases.
/// The returned Package is owned by its Database.
pub fn findDbsSatisfier(self: *Handle, dbs: Database.List, depstring: [*:0]const u8) ?Package {
    const pkg_ptr = c.alpm_find_dbs_satisfier(self.ptr, dbs.child.list, depstring);
    if (pkg_ptr == null) return null;
    return .{ .ptr = pkg_ptr.? };
}

/// Gets the list of packages to be added in the current transaction.
/// The returned list is owned by the transaction and is valid until it is released.
pub fn getAddList(self: *const Handle) Package.List {
    return .fromList(c.alpm_trans_get_add(self.ptr));
}

/// Gets the list of packages to be removed in the current transaction.
/// The returned list is owned by the transaction and is valid until it is released.
pub fn getRemoveList(self: *const Handle) Package.List {
    return .fromList(c.alpm_trans_get_remove(self.ptr));
}

/// Interrupts an ongoing transaction.
pub fn transactionInterrupt(self: *Handle) !void {
    if (c.alpm_trans_interrupt(self.ptr) != 0) {
        @branchHint(.unlikely);
        return self.getErrno();
    }
}

pub fn getSandboxUser(self: Handle) ?[]const u8 {
    return if (self.getSandboxUserSentinel()) |user| mem.sliceTo(user, 0) else null;
}

pub fn getSandboxUserSentinel(self: Handle) [*c]const u8 {
    return c.alpm_option_get_sandboxuser(self.ptr);
}

/// Remove the database lock file
/// Safe to call from inside signal handlers.
pub fn unlock(self: *Handle) void {
    _ = c.alpm_unlock(self.ptr);
}

fn fetchFile(handle: *Handle, url: []const u8, local_path: []const u8) !void {
    const gpa = handle.arena.child_allocator;
    var dir = try std.fs.cwd().openDir(local_path, .{});
    defer dir.close();

    const uri = try std.Uri.parse(url);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const filename = std.fs.path.basename(try uri.path.toRaw(&path_buf));
    var file = try dir.createFile(filename, .{ .truncate = true });
    defer file.close();

    const cleaned_filename = if (mem.indexOf(u8, filename, ".pkg.")) |index|
        filename[0..index]
    else if (mem.endsWith(u8, filename, ".db"))
        filename[0 .. filename.len - 3]
    else
        filename;

    const is_signature_file = mem.endsWith(u8, filename, ".sig");
    const progress_maybe = if (!is_signature_file) handle.blocking_op.start(cleaned_filename, 1) else null;
    defer if (progress_maybe) |progress| {
        progress.completeOne();
        progress.end();
    };

    var buf: [8 * 1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    var http_client: std.http.Client = .{ .allocator = gpa };
    defer http_client.deinit();

    const result = try http_client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = writer,
    });

    try writer.flush();

    if (result.status != .ok) {
        log.err("failed to fetch file: {s}, status code: {t}", .{
            filename,
            result.status,
        });
    }
}

fn fetchCallback(
    ctx: ?*anyopaque,
    url_cstr: [*c]const u8,
    local_path_cstr: [*c]const u8,
    force: c_int,
) callconv(.c) c_int {
    _ = force;
    const handle: *Handle = @ptrCast(@alignCast(ctx.?));
    const url = mem.span(url_cstr);
    const local_path = mem.sliceTo(local_path_cstr, 0);
    handle.fetchFile(url, local_path) catch return -1;
    return 0;
}

fn eventCallback(ctx: ?*anyopaque, event: [*c]c.alpm_event_t) callconv(.c) void {
    log.debug("event cb={d}", .{event.*.type});
    var handle: *Handle = @ptrCast(@alignCast(ctx.?));
    switch (event.*.type) {
        c.ALPM_EVENT_HOOK_START => {
            if (event.*.hook.when == c.ALPM_HOOK_PRE_TRANSACTION) {
                handle.blocking_op = handle.progress.start("Running pre-transaction hooks", 0);
            } else {
                handle.blocking_op = handle.progress.start("Running post-transaction hooks", 0);
            }
        },
        c.ALPM_EVENT_HOOK_DONE => handle.blocking_op.end(),
        c.ALPM_EVENT_HOOK_RUN_START => {
            const e = &event.*.hook_run;
            const name = if (e.desc) |d| d else e.name;
            log.debug(
                "hook run start: position={d}, total={d}, {s}",
                .{ e.position, e.total, name },
            );
            handle.blocking_op.setEstimatedTotalItems(e.total);
            handle.run_hook_op = handle.blocking_op.start(mem.span(name), 1);
        },
        c.ALPM_EVENT_HOOK_RUN_DONE => {
            handle.run_hook_op.completeOne();
            handle.run_hook_op.end();
        },
        c.ALPM_EVENT_CHECKDEPS_START => {
            handle.blocking_op = handle.progress.start("checking dependencies", 0);
        },
        c.ALPM_EVENT_CHECKDEPS_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_RESOLVEDEPS_START => {
            handle.blocking_op = handle.progress.start("resolving dependencies", 0);
        },
        c.ALPM_EVENT_RESOLVEDEPS_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_INTERCONFLICTS_START => {
            handle.blocking_op = handle.progress.start("looking for conflicting packages", 0);
        },
        c.ALPM_EVENT_INTERCONFLICTS_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_KEYRING_START => {
            handle.blocking_op = handle.progress.start("checking keyring", 0);
        },
        c.ALPM_EVENT_KEYRING_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_KEY_DOWNLOAD_START => {
            handle.blocking_op = handle.progress.start("downloading required keys", 0);
        },
        c.ALPM_EVENT_KEY_DOWNLOAD_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_DB_RETRIEVE_START => {
            const count = handle.getSyncDbs().count();
            handle.blocking_op = handle.progress.start("Synchronizing package databases", count);
        },
        c.ALPM_EVENT_DB_RETRIEVE_FAILED,
        c.ALPM_EVENT_DB_RETRIEVE_DONE,
        => handle.blocking_op.end(),
        c.ALPM_EVENT_PKG_RETRIEVE_START => {
            const count = handle.getAddList().count();
            handle.blocking_op = handle.progress.start("Retrieving packages", count);
        },
        c.ALPM_EVENT_PKG_RETRIEVE_FAILED,
        c.ALPM_EVENT_PKG_RETRIEVE_DONE,
        => handle.blocking_op.end(),
        c.ALPM_EVENT_TRANSACTION_START => {
            const count = handle.getAddList().count() + handle.getRemoveList().count();
            handle.blocking_op = if (count > 0)
                handle.progress.start("Processing package changes", count)
            else
                .none;
        },
        c.ALPM_EVENT_TRANSACTION_DONE => handle.blocking_op.end(),
        c.ALPM_EVENT_PACKAGE_OPERATION_START => {
            const e = event.*.package_operation;
            switch (e.operation) {
                c.ALPM_PACKAGE_INSTALL => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    log.debug("Installing package {s}", .{newpkg.getName()});
                    if (handle.install_map.getPtr(newpkg.getName())) |node| {
                        node.* = handle.blocking_op.start(newpkg.getName(), 100);
                    }
                },
                c.ALPM_PACKAGE_UPGRADE => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    log.debug("Upgrading package {s}", .{newpkg.getName()});
                    if (handle.upgrade_map.getPtr(newpkg.getName())) |node| {
                        node.* = handle.blocking_op.start(newpkg.getName(), 100);
                    }
                },
                c.ALPM_PACKAGE_REINSTALL => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    log.debug("Reinstalling package {s}", .{newpkg.getName()});

                    if (handle.reinstall_map.getPtr(newpkg.getName())) |node| {
                        node.* = handle.blocking_op.start(newpkg.getName(), 100);
                    }
                },
                c.ALPM_PACKAGE_DOWNGRADE => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    log.debug("Downgrading package {s}", .{newpkg.getName()});

                    if (handle.downgrade_map.getPtr(newpkg.getName())) |node| {
                        node.* = handle.blocking_op.start(newpkg.getName(), 100);
                    }
                },
                c.ALPM_PACKAGE_REMOVE => {
                    const oldpkg: Package = .{ .ptr = e.oldpkg.? };
                    log.debug("Removing package {s}", .{oldpkg.getName()});
                    if (handle.remove_map.getPtr(oldpkg.getName())) |node| {
                        node.* = handle.blocking_op.start(oldpkg.getName(), 100);
                    }
                },
                else => unreachable,
            }
        },
        c.ALPM_EVENT_PACKAGE_OPERATION_DONE => {
            const e = event.*.package_operation;
            switch (e.operation) {
                c.ALPM_PACKAGE_INSTALL => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    if (handle.install_map.getPtr(newpkg.getName())) |node| {
                        node.end();
                    }
                },
                c.ALPM_PACKAGE_UPGRADE => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    if (handle.install_map.getPtr(newpkg.getName())) |node| {
                        node.end();
                    }
                },
                c.ALPM_PACKAGE_REINSTALL => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    if (handle.install_map.getPtr(newpkg.getName())) |node| {
                        node.end();
                    }
                },
                c.ALPM_PACKAGE_DOWNGRADE => {
                    const newpkg: Package = .{ .ptr = e.newpkg.? };
                    if (handle.install_map.getPtr(newpkg.getName())) |node| {
                        node.end();
                    }
                },
                c.ALPM_PACKAGE_REMOVE => {
                    const oldpkg: Package = .{ .ptr = e.oldpkg.? };
                    if (handle.install_map.getPtr(oldpkg.getName())) |node| {
                        node.end();
                    }
                },
                else => unreachable,
            }
        },
        c.ALPM_EVENT_FILECONFLICTS_START => {
            std.log.debug("fileconflict start", .{});
            handle.blocking_op = handle.progress.start("checking for file conflicts", 100);
        },
        c.ALPM_EVENT_FILECONFLICTS_DONE => {
            std.log.debug("fileconflict done", .{});
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_DISKSPACE_START => {
            handle.blocking_op = handle.progress.start("checking available disk space", 100);
        },
        c.ALPM_EVENT_DISKSPACE_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_INTEGRITY_START => {
            handle.blocking_op = handle.progress.start("checking package integrity", 100);
        },
        c.ALPM_EVENT_INTEGRITY_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_LOAD_START => {
            handle.blocking_op = handle.progress.start("loading package files", 100);
        },
        c.ALPM_EVENT_LOAD_DONE => {
            handle.blocking_op.end();
        },
        c.ALPM_EVENT_SCRIPTLET_INFO => {
            log.debug("script_info: {s}", .{event.*.scriptlet_info.line});
        },
        else => {},
    }
}

fn downloadCallback(
    ctx: ?*anyopaque,
    filename: [*c]const u8,
    event: c.alpm_download_event_type_t,
    data: ?*anyopaque,
) callconv(.c) void {
    log.debug("download cb", .{});
    const handle: *Handle = @ptrCast(@alignCast(ctx.?));
    _ = handle;
    _ = filename;
    _ = data;
    switch (event) {
        c.ALPM_DOWNLOAD_INIT => {},
        c.ALPM_DOWNLOAD_PROGRESS => {},
        c.ALPM_DOWNLOAD_RETRY => {},
        c.ALPM_DOWNLOAD_COMPLETED => {},
        else => unreachable,
    }
}

fn progressCallback(
    ctx: ?*anyopaque,
    event: c.alpm_progress_t,
    pkgname_cstr: [*c]const u8,
    percent_int: c_int,
    howmany: usize,
    current: usize,
) callconv(.c) void {
    _ = howmany;
    _ = current;
    const pkgname = mem.span(pkgname_cstr);
    const handle: *Handle = @ptrCast(@alignCast(ctx.?));

    const percent: usize = @intCast(percent_int);

    switch (event) {
        c.ALPM_PROGRESS_ADD_START => {
            if (handle.install_map.getPtr(pkgname)) |node| {
                node.setCompletedItems(percent);
            }
        },
        c.ALPM_PROGRESS_UPGRADE_START => {
            if (handle.upgrade_map.getPtr(pkgname)) |node| {
                node.setCompletedItems(percent);
            }
        },
        c.ALPM_PROGRESS_DOWNGRADE_START => {
            if (handle.downgrade_map.getPtr(pkgname)) |node| {
                node.setCompletedItems(percent);
            }
        },
        c.ALPM_PROGRESS_REINSTALL_START => {
            if (handle.reinstall_map.getPtr(pkgname)) |node| {
                node.setCompletedItems(percent);
            }
        },
        c.ALPM_PROGRESS_REMOVE_START => {
            if (handle.remove_map.getPtr(pkgname)) |node| {
                node.setCompletedItems(percent);
            }
        },
        c.ALPM_PROGRESS_CONFLICTS_START,
        c.ALPM_PROGRESS_DISKSPACE_START,
        c.ALPM_PROGRESS_INTEGRITY_START,
        c.ALPM_PROGRESS_KEYRING_START,
        c.ALPM_PROGRESS_LOAD_START,
        => handle.blocking_op.setCompletedItems(percent),
        else => unreachable,
    }
}

fn questionCallback(ctx: ?*anyopaque, question: [*c]c.alpm_question_t) callconv(.c) void {
    _ = ctx;
    switch (question.*.type) {
        c.ALPM_QUESTION_INSTALL_IGNOREPKG => {
            var q = &question.*.install_ignorepkg;
            q.install = 0;
        },
        c.ALPM_QUESTION_REPLACE_PKG => {
            var q = &question.*.replace;
            q.replace = 1;
        },
        c.ALPM_QUESTION_CONFLICT_PKG => {
            var q = &question.*.conflict;
            q.remove = 1;
        },
        c.ALPM_QUESTION_REMOVE_PKGS => {
            var q = &question.*.remove_pkgs;
            q.skip = 1;
        },
        c.ALPM_QUESTION_SELECT_PROVIDER => {
            var q = &question.*.select_provider;
            q.use_index = 0;
        },
        c.ALPM_QUESTION_CORRUPTED_PKG => {
            var q = &question.*.corrupted;
            q.remove = 1;
        },
        c.ALPM_QUESTION_IMPORT_KEY => {
            var q = &question.*.import_key;
            q.import = 1;
        },
        else => {},
    }
}

test {
    var handle: Handle = try .init(testing.allocator, c.ROOTDIR, c.DBPATH);
    defer handle.deinit();
    const gpa = handle.arena.allocator();
    handle.setFetchCallback();
    handle.setEventCallback();
    handle.setDownloadCallback();
    handle.setProgressCallback();
    handle.setQuestionCallback();

    try handle.setLogFile(c.LOGFILE);
    try handle.setCacheDirs(try .fromSlice(gpa, &.{c.CACHEDIR}));
    try handle.setGpgDir(c.GPGDIR);
    try handle.addHookDir(c.HOOKDIR);
    try handle.setDefaultSigLevel(.{
        .package = .{ .required = true },
        .database = .{ .optional = true },
    });
    try handle.setLocalFileSigLevel(.{
        .package = .{ .optional = true },
        .database = .{ .optional = true },
    });
    try handle.setRemoteFileSigLevel(.{
        .package = .{ .required = true },
        .database = .{ .required = true },
    });

    //var core_db = try handle.registerSyncDb("core", .{});
    //try core_db.addServer("http://mirrors.ustc.edu.cn/archlinux/core/os/x86_64");
    //var extra_db = try handle.registerSyncDb("extra", .{});
    //try extra_db.addServer("http://mirrors.ustc.edu.cn/archlinux/extra/os/x86_64");

    //var archlinuxcn_db = try handle.registerSyncDb("extra", .{});
    //try archlinuxcn_db.addServer("http://mirrors.ustc.edu.cn/archlinuxcn/x86_64");

    //const sync_dbs = handle.getSyncDbs();
    //_ = try handle.dbUpdate(sync_dbs, true);
}

const c = @import("c");
const c_internal = @import("c_internal");
const std = @import("std");
const log = std.log;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const alpm = @import("../alpm.zig");
const Database = alpm.Database;
const SigLevel = alpm.SigLevel;
const Package = alpm.Package;
const Handle = @This();
