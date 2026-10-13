#ifndef DISK_ACCESS_H
#define DISK_ACCESS_H

/// Outcome of asking macOS for a read-only descriptor on a raw disk.
typedef enum {
    DiskAccessOK = 0,
    /// The person closed the password dialog.
    DiskAccessCancelled = 1,
    /// The password was wrong too many times, or the account isn't allowed.
    DiskAccessDenied = 2,
    /// macOS privacy settings blocked the read (Removable Volumes or Full Disk Access).
    DiskAccessPrivacyBlocked = 3,
    /// Something else went wrong. `detail` holds errno or an OSStatus.
    DiskAccessFailed = 4,
} DiskAccessResult;

/// Asks for an administrator password once, then has /usr/libexec/authopen open `path`
/// read-only and hand the descriptor back over a socket. The app itself never runs as root.
/// `prompt` is shown in the password dialog. On success `*fd_out` holds an O_RDONLY descriptor.
DiskAccessResult disk_access_open_readonly(const char *path, const char *prompt, int *fd_out, int *detail);

#endif
