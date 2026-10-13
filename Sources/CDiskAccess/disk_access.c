#include "disk_access.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int receive_descriptor(int socket_fd) {
    char data = 0;
    struct iovec io = { .iov_base = &data, .iov_len = 1 };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr message = {
        .msg_iov = &io,
        .msg_iovlen = 1,
        .msg_control = control,
        .msg_controllen = sizeof(control),
    };
    ssize_t got;
    do {
        got = recvmsg(socket_fd, &message, 0);
    } while (got < 0 && errno == EINTR);
    if (got <= 0) return -1;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL; header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS && header->cmsg_len == CMSG_LEN(sizeof(int))) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(header), sizeof(int));
            return fd;
        }
    }
    return -1;
}

static void read_all(int fd, char *buffer, size_t capacity) {
    size_t used = 0;
    while (used + 1 < capacity) {
        ssize_t got = read(fd, buffer + used, capacity - used - 1);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        used += (size_t)got;
    }
    buffer[used] = 0;
}

DiskAccessResult disk_access_open_readonly(const char *path, const char *prompt, int *fd_out, int *detail) {
    *fd_out = -1;
    *detail = 0;
    if (path == NULL || strncmp(path, "/dev/", 5) != 0) {
        *detail = EINVAL;
        return DiskAccessFailed;
    }

    char right_name[256];
    snprintf(right_name, sizeof(right_name), "sys.openfile.readonly.%s", path);
    AuthorizationItem right = { right_name, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &right };
    AuthorizationItem environment_items[1];
    AuthorizationEnvironment environment = { 0, environment_items };
    if (prompt != NULL && prompt[0] != 0) {
        environment_items[0].name = kAuthorizationEnvironmentPrompt;
        environment_items[0].valueLength = strlen(prompt);
        environment_items[0].value = (void *)prompt;
        environment_items[0].flags = 0;
        environment.count = 1;
    }

    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) {
        *detail = (int)status;
        return DiskAccessFailed;
    }
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize;
    status = AuthorizationCopyRights(authorization, &rights, &environment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        *detail = (int)status;
        if (status == errAuthorizationCanceled) return DiskAccessCancelled;
        if (status == errAuthorizationDenied || status == errAuthorizationInteractionNotAllowed) return DiskAccessDenied;
        return DiskAccessFailed;
    }
    AuthorizationExternalForm external;
    status = AuthorizationMakeExternalForm(authorization, &external);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        *detail = (int)status;
        return DiskAccessFailed;
    }

    int sockets[2] = { -1, -1 };
    int input[2] = { -1, -1 };
    int errors[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0 || pipe(input) != 0 || pipe(errors) != 0) {
        *detail = errno;
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return DiskAccessFailed;
    }

    // Writing the authorization to a pipe authopen has already closed must fail, not kill the app.
    fcntl(input[1], F_SETNOSIGPIPE, 1);

    // Only the three descriptors set up below reach authopen; none of the app's other open files do.
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO);

    char *arguments[] = { "/usr/libexec/authopen", "-stdoutpipe", "-extauth", (char *)path, NULL };
    pid_t child = 0;
    int spawned = posix_spawn(&child, arguments[0], &actions, &attributes, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(input[0]);
    close(sockets[1]);
    close(errors[1]);
    if (spawned != 0) {
        *detail = spawned;
        close(input[1]);
        close(sockets[0]);
        close(errors[0]);
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return DiskAccessFailed;
    }

    ssize_t written = write(input[1], &external, sizeof(external));
    close(input[1]);

    int fd = written == (ssize_t)sizeof(external) ? receive_descriptor(sockets[0]) : -1;
    close(sockets[0]);

    char message[512];
    read_all(errors[0], message, sizeof(message));
    close(errors[0]);

    int child_status = 0;
    while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {}
    AuthorizationFree(authorization, kAuthorizationFlagDefaults);

    if (fd >= 0) {
        int mode = fcntl(fd, F_GETFL);
        if (mode < 0 || (mode & O_ACCMODE) != O_RDONLY) {
            close(fd);
            *detail = EPERM;
            return DiskAccessFailed;
        }
        *fd_out = fd;
        return DiskAccessOK;
    }
    if (strstr(message, "Operation not permitted") != NULL) {
        *detail = EPERM;
        return DiskAccessPrivacyBlocked;
    }
    if (strstr(message, "Permission denied") != NULL || strstr(message, "not authorized") != NULL) {
        *detail = EACCES;
        return DiskAccessDenied;
    }
    *detail = WIFEXITED(child_status) ? WEXITSTATUS(child_status) : -1;
    return DiskAccessFailed;
}
