/**
 * PersonaSpawn.c — AgentBox Root Persona Spawn Implementation
 *
 * Provides C-level wrappers around the undocumented libpersona.dylib API
 * for creating root (UID=0) personas and spawning child processes with them.
 *
 * Target: iOS 16.6.1, ARM64, TrollStore 2 (persona-mgmt entitlement).
 *
 * API surface (exposed via AgentBox-Bridging-Header.h):
 *   - agentbox_persona_alloc_root()
 *   - agentbox_persona_dealloc()
 *   - agentbox_spawn_with_persona()
 *   - agentbox_spawn_root_simple()
 *   - agentbox_fork_root_spawn()
 *   - agentbox_boot_ish_kernel()
 */

#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <dlfcn.h>

// ---- Undocumented libpersona types and constants ----

#define KPERSONA_INFO_VERSION_1 1
#define KPERSONA_ID_MAX         10
#define POSIX_SPAWN_PERSONA_FLAGS_ROOT 1

/// Undocumented kernel persona info structure.
/// Fields are reverse-engineered from AppleMobileFileIntegrity / XNU sources.
typedef struct {
    uint32_t persona_info_version;
    uid_t    persona_id;          // output: assigned persona ID
    int32_t  persona_type;        // 0 = guest (root context), 1 = system
    uint32_t persona_flags;       // bitmask flags
    uid_t    persona_uid;         // target UID (0 for root)
    gid_t    persona_gid;         // target GID (0 for wheel)
    char     persona_name[128];   // descriptive label
    uint8_t  _reserved[4096 - 128 - 4*5 - 2*4]; // pad to 4KB
} kpersona_info_t;

// ---- Dynamic function pointers (loaded from libpersona.dylib) ----

/// Typedef for kpersona_alloc: int kpersona_alloc(kpersona_info_t *info, uid_t *out_id)
typedef int (*kpersona_alloc_fn)(kpersona_info_t *info, uid_t *out_id);

/// Typedef for kpersona_dealloc: int kpersona_dealloc(uid_t persona_id)
typedef int (*kpersona_dealloc_fn)(uid_t persona_id);

/// Typedef for posix_spawnattr_set_persona_np
typedef int (*posix_spawnattr_set_persona_np_fn)(
    posix_spawnattr_t *attr, uid_t persona_id, uint32_t flags
);

/// Typedef for posix_spawnattr_set_persona_flags
typedef int (*posix_spawnattr_set_persona_flags_fn)(
    posix_spawnattr_t *attr, uint32_t flags
);

// ---- Helper: load libpersona function by name ----

static void *persona_handle = NULL;

/// Lazily dlopen /usr/lib/libpersona.dylib and resolve a symbol.
/// Returns the function pointer or NULL on failure.
static void *agentbox_dlsym_persona(const char *symbol_name) {
    if (persona_handle == NULL) {
        persona_handle = dlopen("/usr/lib/libpersona.dylib", RTLD_NOW);
        if (persona_handle == NULL) {
            // Fallback: try alternate path for iOS 16
            persona_handle = dlopen("/usr/lib/system/libpersona.dylib", RTLD_NOW);
        }
        if (persona_handle == NULL) {
            return NULL;
        }
    }
    return dlsym(persona_handle, symbol_name);
}

/// Close the libpersona handle (called at process exit or after dealloc).
static void agentbox_dlclose_persona(void) {
    if (persona_handle != NULL) {
        dlclose(persona_handle);
        persona_handle = NULL;
    }
}

// ---- Public API Implementation ----

int agentbox_persona_alloc_root(uint32_t *out_persona_id) {
    if (out_persona_id == NULL) {
        errno = EINVAL;
        return -1;
    }

    kpersona_alloc_fn kpersona_alloc_ptr =
        (kpersona_alloc_fn)agentbox_dlsym_persona("kpersona_alloc");
    if (kpersona_alloc_ptr == NULL) {
        errno = ENOSYS;
        return -1;
    }

    kpersona_info_t info;
    memset(&info, 0, sizeof(info));
    info.persona_info_version = KPERSONA_INFO_VERSION_1;
    info.persona_type        = 0;    // guest persona
    info.persona_flags       = 0;
    info.persona_uid         = 0;    // root
    info.persona_gid         = 0;    // wheel
    // Copy a short label for debugging
    const char *label = "com.agentbox.root";
    strncpy(info.persona_name, label, sizeof(info.persona_name) - 1);

    uid_t persona_id = 0;
    int ret = kpersona_alloc_ptr(&info, &persona_id);
    if (ret != 0) {
        errno = (ret < 0) ? -ret : ret;
        return -1;
    }

    *out_persona_id = (uint32_t)persona_id;
    return 0;
}

int agentbox_persona_dealloc(uint32_t persona_id) {
    kpersona_dealloc_fn kpersona_dealloc_ptr =
        (kpersona_dealloc_fn)agentbox_dlsym_persona("kpersona_dealloc");
    if (kpersona_dealloc_ptr == NULL) {
        errno = ENOSYS;
        return -1;
    }

    int ret = kpersona_dealloc_ptr((uid_t)persona_id);
    if (ret != 0) {
        errno = (ret < 0) ? -ret : ret;
        return -1;
    }
    return 0;
}

int agentbox_spawn_with_persona(
    uint32_t persona_id,
    const char *binary_path,
    char *const argv[],
    char *const envp[],
    int *out_stdout_fd,
    int *out_stderr_fd,
    pid_t *out_pid
) {
    if (binary_path == NULL || argv == NULL ||
        out_stdout_fd == NULL || out_stderr_fd == NULL || out_pid == NULL) {
        errno = EINVAL;
        return -1;
    }

    posix_spawnattr_set_persona_np_fn set_persona_fn =
        (posix_spawnattr_set_persona_np_fn)agentbox_dlsym_persona(
            "posix_spawnattr_set_persona_np");
    if (set_persona_fn == NULL) {
        errno = ENOSYS;
        return -1;
    }

    // Create stdout pipe
    int stdout_pipe[2];
    if (pipe(stdout_pipe) != 0) {
        return -1;
    }

    // Create stderr pipe
    int stderr_pipe[2];
    if (pipe(stderr_pipe) != 0) {
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        return -1;
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // Set persona
    int ret = set_persona_fn(&attr, (uid_t)persona_id, POSIX_SPAWN_PERSONA_FLAGS_ROOT);
    if (ret != 0) {
        posix_spawnattr_destroy(&attr);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        errno = (ret < 0) ? -ret : ret;
        return -1;
    }

    // Configure file actions: redirect stdout and stderr to pipes
    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_addclose(&file_actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&file_actions, stderr_pipe[0]);
    posix_spawn_file_actions_adddup2(&file_actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&file_actions, stderr_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&file_actions, stdout_pipe[1]);
    posix_spawn_file_actions_addclose(&file_actions, stderr_pipe[1]);

    // Set spawn flags
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;
    posix_spawnattr_setflags(&attr, flags);

    pid_t pid = 0;
    ret = posix_spawn(&pid, binary_path, &file_actions, &attr, argv, envp);

    posix_spawn_file_actions_destroy(&file_actions);
    posix_spawnattr_destroy(&attr);

    // Close write ends in parent
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    if (ret != 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        errno = ret;
        return -1;
    }

    *out_stdout_fd = stdout_pipe[0];
    *out_stderr_fd = stderr_pipe[0];
    *out_pid = pid;
    return 0;
}

int agentbox_spawn_root_simple(
    const char *command,
    char **out_stdout,
    char **out_stderr,
    int *out_exit_code
) {
    if (command == NULL || out_stdout == NULL ||
        out_stderr == NULL || out_exit_code == NULL) {
        errno = EINVAL;
        return -1;
    }

    uint32_t persona_id = 0;
    if (agentbox_persona_alloc_root(&persona_id) != 0) {
        // Persona unavailable — fall through to fork method below
        // (caller should have already tried fork path, but we handle here)
        return -1;
    }

    // Build argv for /bin/sh -c <command>
    char *argv[] = {
        (char *)"/bin/sh",
        (char *)"-c",
        (char *)command,
        NULL
    };

    // Set minimal PATH for root context
    char *envp[] = {
        (char *)"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        (char *)"HOME=/var/root",
        NULL
    };

    int stdout_fd = -1, stderr_fd = -1;
    pid_t pid = 0;

    if (agentbox_spawn_with_persona(persona_id, "/bin/sh", argv, envp,
                                     &stdout_fd, &stderr_fd, &pid) != 0) {
        agentbox_persona_dealloc(persona_id);
        return -1;
    }

    // Read all output from pipes
    #define READ_BUF_SIZE 65536
    char *stdout_buf = (char *)malloc(READ_BUF_SIZE);
    char *stderr_buf = (char *)malloc(READ_BUF_SIZE);
    if (stdout_buf == NULL || stderr_buf == NULL) {
        free(stdout_buf);
        free(stderr_buf);
        close(stdout_fd);
        close(stderr_fd);
        agentbox_persona_dealloc(persona_id);
        errno = ENOMEM;
        return -1;
    }

    ssize_t stdout_len = 0, stderr_len = 0;
    ssize_t n;

    // Non-blocking read loop for stdout
    while ((n = read(stdout_fd, stdout_buf + stdout_len,
                     READ_BUF_SIZE - stdout_len - 1)) > 0) {
        stdout_len += n;
        if ((size_t)stdout_len >= READ_BUF_SIZE - 1) break;
    }
    stdout_buf[stdout_len] = '\0';

    // Non-blocking read loop for stderr
    while ((n = read(stderr_fd, stderr_buf + stderr_len,
                     READ_BUF_SIZE - stderr_len - 1)) > 0) {
        stderr_len += n;
        if ((size_t)stderr_len >= READ_BUF_SIZE - 1) break;
    }
    stderr_buf[stderr_len] = '\0';

    close(stdout_fd);
    close(stderr_fd);

    // Wait for child
    int status = 0;
    waitpid(pid, &status, 0);

    agentbox_persona_dealloc(persona_id);

    *out_stdout = stdout_buf;
    *out_stderr = stderr_buf;
    *out_exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return 0;
}

int agentbox_fork_root_spawn(
    const char *binary_path,
    char *const argv[],
    char *const envp[],
    int *out_stdout_fd,
    int *out_stderr_fd,
    pid_t *out_pid
) {
    if (binary_path == NULL || argv == NULL ||
        out_stdout_fd == NULL || out_stderr_fd == NULL || out_pid == NULL) {
        errno = EINVAL;
        return -1;
    }

    int stdout_pipe[2];
    int stderr_pipe[2];

    if (pipe(stdout_pipe) != 0) return -1;
    if (pipe(stderr_pipe) != 0) {
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        // Fork failed
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return -1;
    }

    if (pid == 0) {
        // ---- Child process ----
        // Redirect stdout
        close(stdout_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        close(stdout_pipe[1]);

        // Redirect stderr
        close(stderr_pipe[0]);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stderr_pipe[1]);

        // Attempt setuid(0). In TrollStore no-sandbox context this should succeed.
        if (setuid(0) != 0) {
            // If setuid fails, try setgid + setuid via setreuid
            setreuid(0, 0);
        }
        setgid(0);

        // Execute target binary
        if (envp != NULL) {
            execve(binary_path, argv, envp);
        } else {
            execv(binary_path, argv);
        }

        // execve failed — exit with error
        _exit(127);
    }

    // ---- Parent process ----
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    *out_stdout_fd = stdout_pipe[0];
    *out_stderr_fd = stderr_pipe[0];
    *out_pid = pid;
    return 0;
}

// ---- ish Kernel Boot Bridge ----

/// Forward declaration from ish kernel/init.h
/// In practice this is linked from libish.a.
extern int actuate_kernel(const char *root_path);

int agentbox_boot_ish_kernel(const char *root_path) {
    if (root_path == NULL) {
        errno = EINVAL;
        return -1;
    }

    // Validate root path exists
    struct stat st;
    if (stat(root_path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        errno = ENOENT;
        return -1;
    }

    // Call actuate_kernel from libish.a
    // This initializes the Linux kernel emulation with the given rootfs.
    int result = actuate_kernel(root_path);
    return result;
}

// MARK: - waitpid Macro Wrappers (Swift can't call C macros directly)

/// Returns 1 if the child exited normally, 0 otherwise.
int agentbox_wifexited(int status) {
    return WIFEXITED(status) ? 1 : 0;
}

/// Returns the exit status of the child (only valid if WIFEXITED is true).
int agentbox_wexitstatus(int status) {
    return WEXITSTATUS(status);
}

/// Returns 1 if the child was terminated by a signal, 0 otherwise.
int agentbox_wifsignaled(int status) {
    return WIFSIGNALED(status) ? 1 : 0;
}

/// Returns the signal number that terminated the child.
int agentbox_wtermsig(int status) {
    return WTERMSIG(status);
}
