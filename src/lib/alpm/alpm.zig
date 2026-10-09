pub const Handle = @import("alpm/Handle.zig");
pub const List = @import("alpm/list.zig").List;
pub const ListWrapper = @import("alpm/list.zig").ListWrapper;
pub const StringList = List([*:0]const u8);
pub const Database = @import("alpm/Database.zig");
pub const File = @import("alpm/File.zig");
pub const FileList = @import("alpm/FileList.zig");
pub const Package = @import("alpm/Package.zig");
pub const Group = @import("alpm/Group.zig");
pub const Depend = @import("alpm/Depend.zig");

pub const Defaults = struct {
    rootdir: [:0]const u8,
    logfile: [:0]const u8,
    dbpath: [:0]const u8,
    cachedir: [:0]const u8,
    hookdir: [:0]const u8,
    gpgdir: [:0]const u8,
};

pub const defaults: Defaults = .{
    .rootdir = c.ROOTDIR,
    .dbpath = c.DBPATH,
    .logfile = c.LOGFILE,
    .cachedir = c.CACHEDIR,
    .hookdir = c.HOOKDIR,
    .gpgdir = c.GPGDIR,
};

const buf_size = 8192;

/// Represents the signature verification level for packages and databases.
/// This is a packed struct to map directly to the alpm_siglevel_t bitmask.
pub const SigLevel = packed struct(c_int) {
    // --- Package Flags ---
    package: packed struct(u4) {
        /// Packages require a signature.
        required: bool = false,

        /// Packages do not require a signature, but check packages that do have signatures.
        optional: bool = false,

        /// Allow packages with signatures that are marginal trust.
        marginal_ok: bool = false,

        /// Allow packages with signatures that are unknown trust.
        unknown: bool = false,
    } = .{},

    /// Padding for unused bits 4 through 9.
    _padding1: u6 = 0,

    // --- Database Flags ---
    database: packed struct(u4) {
        /// Databases require a signature.
        required: bool = false, // bit 10

        /// Databases do not require a signature, but check packages that do have signatures.
        optional: bool = false,

        /// Allow Databases with signatures that are marginal trust.
        marginal_ok: bool = false,

        /// Allow Databases with signatures that are unknown trust.
        unknown: bool = false,
    } = .{},

    /// Padding for unused bits 14 through 29.
    _padding2: u16 = 0,

    // --- Control Flag ---

    /// Use the default siglevel.
    use_default: bool = false, // bit 30

    /// Padding for the final unused bit to align to 32 bits.
    _padding3: u1 = 0,

    // Ensure at compile time that this struct is the size of a u32.
    comptime {
        std.debug.assert(@sizeOf(SigLevel) == @sizeOf(c_int));
    }
};

/// Flags for transaction behavior.
pub const TransactionFlags = packed struct(c_int) {
    // Ignore dependency checks.
    nodeps: bool = false,
    // (1 << 1) flag can go here
    _p1: bool = false,
    // Delete files even if they are tagged as backup.
    nosave: bool = false,
    // Ignore version numbers when checking dependencies.
    nodepversion: bool = false,
    // Remove also any packages depending on a package being removed.
    cascade: bool = false,
    // Remove packages and their unneeded deps (not explicitly installed).
    recurse: bool = true,
    // Modify database but do not commit changes to the filesystem.
    dbonly: bool = false,
    // Do not run hooks during a transaction
    nohooks: bool = false,
    // Use ALPM_PKG_REASON_DEPEND when installing packages.
    alldeps: bool = false,
    // Only download packages and do not actually install.
    downloadonly: bool = false,
    // Do not execute install scriptlets after installing.
    noscriptlet: bool = false,
    // Ignore dependency conflicts.
    noconflicts: bool = false,
    // (1 << 12) flag can go here
    _p2: bool = false, // 1 << 1 (reserved)
    // Do not install a package if it is already installed and up to date.
    needed: bool = true,
    // Use ALPM_PKG_REASON_EXPLICIT when installing packages.
    allexplicit: bool = false,
    // Do not remove a package if it is needed by another one.
    unneeded: bool = true,
    // Remove also explicitly installed unneeded deps (use with ALPM_TRANS_FLAG_RECURSE).
    recurseall: bool = false,
    // Do not lock the database during the operation.
    nolock: bool = false,
    padding: u14 = 0,

    // Ensure at compile time that this struct is the size of a u32.
    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(c_int));
    }
};

pub const Error = error{
    // System
    OutOfMemory,
    SystemFailure,
    PermissionDenied,
    FileNotFound,
    DirectoryNotFound,
    InvalidArgument,
    NotEnoughDiskSpace,

    // Interface
    NotInitialized,
    AlreadyInitialized,
    DatabaseLockFailed,

    // Databases
    DatabaseOpenFailed,
    DatabaseCreateFailed,
    DatabaseNotInitialized,
    DatabaseAlreadyRegistered,
    DatabaseNotFound,
    InvalidDatabase,
    InvalidDatabaseSignature,
    IncorrectDatabaseVersion,
    DatabaseWriteFailed,
    DatabaseRemoveEntryFailed,

    // Servers
    InvalidServerUrl,
    NoServersConfigured,

    // Transactions
    TransactionAlreadyInitialized,
    TransactionNotInitialized,
    DuplicateTarget,
    DuplicateFilename,
    TransactionNotPrepared,
    TransactionAborted,
    IncompatibleTransactionType,
    DatabaseNotLocked,
    TransactionHookFailed,

    // Packages
    PackageNotFound,
    PackageIgnored,
    InvalidPackage,
    InvalidPackageChecksum,
    InvalidPackageSignature,
    PackageMissingSignature,
    PackageOpenFailed,
    PackageRemoveFailed,
    InvalidPackageName,
    InvalidPackageArchitecture,

    // Signatures
    MissingSignature,
    InvalidSignature,

    // Dependencies
    UnsatisfiedDependencies,
    ConflictingDependencies,
    FileConflicts,

    // Miscellaneous
    FileRetrievalFailed,
    InvalidRegex,

    // External Libraries
    LibArchive,
    LibCurl,
    Gpgme,
    ExternalDownloaderFailed,

    // Missing compile-time features
    SignatureSupportNotCompiled,

    Unexpected,
};

/// Converts the C alpm_errno to the corresponding Zig error.
/// This function should only be called when a C function has already indicated failure.
/// Calling this when no error has occurred will result in `unreachable`.
pub fn errnoToError(err: c.alpm_errno_t) Error {
    return switch (err) {
        0 => unreachable,
        // System
        c.ALPM_ERR_MEMORY => error.OutOfMemory,
        c.ALPM_ERR_SYSTEM => error.SystemFailure,
        c.ALPM_ERR_BADPERMS => error.PermissionDenied,
        c.ALPM_ERR_NOT_A_FILE => error.FileNotFound,
        c.ALPM_ERR_NOT_A_DIR => error.DirectoryNotFound,
        c.ALPM_ERR_WRONG_ARGS => error.InvalidArgument,
        c.ALPM_ERR_DISK_SPACE => error.NotEnoughDiskSpace,

        // Interface
        c.ALPM_ERR_HANDLE_NULL => error.NotInitialized,
        c.ALPM_ERR_HANDLE_NOT_NULL => error.AlreadyInitialized,
        c.ALPM_ERR_HANDLE_LOCK => error.DatabaseLockFailed,

        // Databases
        c.ALPM_ERR_DB_OPEN => error.DatabaseOpenFailed,
        c.ALPM_ERR_DB_CREATE => error.DatabaseCreateFailed,
        c.ALPM_ERR_DB_NULL => error.DatabaseNotInitialized,
        c.ALPM_ERR_DB_NOT_NULL => error.DatabaseAlreadyRegistered,
        c.ALPM_ERR_DB_NOT_FOUND => error.DatabaseNotFound,
        c.ALPM_ERR_DB_INVALID => error.InvalidDatabase,
        c.ALPM_ERR_DB_INVALID_SIG => error.InvalidDatabaseSignature,
        c.ALPM_ERR_DB_VERSION => error.IncorrectDatabaseVersion,
        c.ALPM_ERR_DB_WRITE => error.DatabaseWriteFailed,
        c.ALPM_ERR_DB_REMOVE => error.DatabaseRemoveEntryFailed,

        // Servers
        c.ALPM_ERR_SERVER_BAD_URL => error.InvalidServerUrl,
        c.ALPM_ERR_SERVER_NONE => error.NoServersConfigured,

        // Transactions
        c.ALPM_ERR_TRANS_NOT_NULL => error.TransactionAlreadyInitialized,
        c.ALPM_ERR_TRANS_NULL => error.TransactionNotInitialized,
        c.ALPM_ERR_TRANS_DUP_TARGET => error.DuplicateTarget,
        c.ALPM_ERR_TRANS_DUP_FILENAME => error.DuplicateFilename,
        c.ALPM_ERR_TRANS_NOT_INITIALIZED => error.TransactionNotInitialized,
        c.ALPM_ERR_TRANS_NOT_PREPARED => error.TransactionNotPrepared,
        c.ALPM_ERR_TRANS_ABORT => error.TransactionAborted,
        c.ALPM_ERR_TRANS_TYPE => error.IncompatibleTransactionType,
        c.ALPM_ERR_TRANS_NOT_LOCKED => error.DatabaseNotLocked,
        c.ALPM_ERR_TRANS_HOOK_FAILED => error.TransactionHookFailed,

        // Packages
        c.ALPM_ERR_PKG_NOT_FOUND => error.PackageNotFound,
        c.ALPM_ERR_PKG_IGNORED => error.PackageIgnored,
        c.ALPM_ERR_PKG_INVALID => error.InvalidPackage,
        c.ALPM_ERR_PKG_INVALID_CHECKSUM => error.InvalidPackageChecksum,
        c.ALPM_ERR_PKG_INVALID_SIG => error.InvalidPackageSignature,
        c.ALPM_ERR_PKG_MISSING_SIG => error.PackageMissingSignature,
        c.ALPM_ERR_PKG_OPEN => error.PackageOpenFailed,
        c.ALPM_ERR_PKG_CANT_REMOVE => error.PackageRemoveFailed,
        c.ALPM_ERR_PKG_INVALID_NAME => error.InvalidPackageName,
        c.ALPM_ERR_PKG_INVALID_ARCH => error.InvalidPackageArchitecture,

        // Signatures
        c.ALPM_ERR_SIG_MISSING => error.MissingSignature,
        c.ALPM_ERR_SIG_INVALID => error.InvalidSignature,

        // Dependencies
        c.ALPM_ERR_UNSATISFIED_DEPS => error.UnsatisfiedDependencies,
        c.ALPM_ERR_CONFLICTING_DEPS => error.ConflictingDependencies,
        c.ALPM_ERR_FILE_CONFLICTS => error.FileConflicts,

        // Miscellaneous
        c.ALPM_ERR_RETRIEVE => error.FileRetrievalFailed,
        c.ALPM_ERR_INVALID_REGEX => error.InvalidRegex,

        // External Libraries
        c.ALPM_ERR_LIBARCHIVE => error.LibArchive,
        c.ALPM_ERR_LIBCURL => error.LibCurl,
        c.ALPM_ERR_GPGME => error.Gpgme,
        c.ALPM_ERR_EXTERNAL_DOWNLOAD => error.ExternalDownloaderFailed,

        // Missing compile-time features
        c.ALPM_ERR_MISSING_CAPABILITY_SIGNATURES => error.SignatureSupportNotCompiled,

        // Handle any unknown error codes that may appear in future versions.
        else => error.Unexpected,
    };
}

const std = @import("std");
const c = @import("c");

test {
    _ = Handle;
}
