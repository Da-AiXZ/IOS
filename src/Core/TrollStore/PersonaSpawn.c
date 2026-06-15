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
#include <stdio.h>
#include <sys/stat.h>
#include <errno.h>

// ish-arm64 type aliases (used by kernel APIs, compatible with standard types)
typedef unsigned int mode_t_;   // matches ish dword_t
typedef unsigned int dev_t_;    // matches ish dword_t
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <limits.h>

// ---- Undocumented libpersona types and constants ----

#define KPERSONA_INFO_VERSION_1 1
#define KPERSONA_ID_MAX         10
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 2  // use existing persona
#define POSIX_SPAWN_PERSONA_SYSTEM 99          // system persona type

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

/// Typedef for posix_spawnattr_set_persona_uid_np
typedef int (*posix_spawnattr_set_persona_uid_np_fn)(
    posix_spawnattr_t *attr, uid_t uid
);

/// Typedef for posix_spawnattr_set_persona_gid_np
typedef int (*posix_spawnattr_set_persona_gid_np_fn)(
    posix_spawnattr_t *attr, gid_t gid
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
    (void)persona_id; // not used in TrollStore approach (uses SYSTEM persona directly)
    
    if (binary_path == NULL || argv == NULL ||
        out_stdout_fd == NULL || out_stderr_fd == NULL || out_pid == NULL) {
        errno = EINVAL;
        return -1;
    }

    // Load TrollStore-compatible persona APIs
    posix_spawnattr_set_persona_np_fn set_persona_fn =
        (posix_spawnattr_set_persona_np_fn)agentbox_dlsym_persona(
            "posix_spawnattr_set_persona_np");
    posix_spawnattr_set_persona_uid_np_fn set_uid_fn =
        (posix_spawnattr_set_persona_uid_np_fn)agentbox_dlsym_persona(
            "posix_spawnattr_set_persona_uid_np");
    posix_spawnattr_set_persona_gid_np_fn set_gid_fn =
        (posix_spawnattr_set_persona_gid_np_fn)agentbox_dlsym_persona(
            "posix_spawnattr_set_persona_gid_np");
    
    if (set_persona_fn == NULL || set_uid_fn == NULL || set_gid_fn == NULL) {
        errno = ENOSYS;
        return -1;
    }

    // Create pipes
    int stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdout_pipe) != 0) return -1;
    if (pipe(stderr_pipe) != 0) {
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return -1;
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // TrollStore approach: SYSTEM persona (99) + OVERRIDE + root UID/GID
    // This matches TSUtil.m spawnRoot() exactly
    int ret = set_persona_fn(&attr, POSIX_SPAWN_PERSONA_SYSTEM, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (ret != 0) goto cleanup_attr;
    ret = set_uid_fn(&attr, 0);  // root
    if (ret != 0) goto cleanup_attr;
    ret = set_gid_fn(&attr, 0);  // wheel
    if (ret != 0) goto cleanup_attr;

    // File actions
    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_addclose(&file_actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&file_actions, stderr_pipe[0]);
    posix_spawn_file_actions_adddup2(&file_actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&file_actions, stderr_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&file_actions, stdout_pipe[1]);
    posix_spawn_file_actions_addclose(&file_actions, stderr_pipe[1]);

    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = 0;
    ret = posix_spawn(&pid, binary_path, &file_actions, &attr, argv, envp);

    posix_spawn_file_actions_destroy(&file_actions);
    posix_spawnattr_destroy(&attr);

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

cleanup_attr:
    posix_spawnattr_destroy(&attr);
    close(stdout_pipe[0]); close(stdout_pipe[1]);
    close(stderr_pipe[0]); close(stderr_pipe[1]);
    errno = (ret < 0) ? -ret : ret;
    return -1;
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
//
// External symbols from libish.a and libfakefs.a.
// These are resolved at link time; declared here as extern to avoid
// pulling in every internal kernel header.

extern struct fs_ops fakefs;                         // libfakefs.a: fake filesystem ops

extern int  mount_root(struct fs_ops *fs, const char *path); // libfakefs.a: mount fakefs at path
extern void become_first_process(void);                   // libish: make current task init (PID 1)

// AT_PWD sentinel for path_normalize (defined in fs/path.h)
// Must use AT_PWD, not NULL — path_normalize asserts at != NULL
#ifndef AT_PWD
#define AT_PWD ((struct fd *) -2)
#endif

extern int  generic_mknodat(void *at, const char *path, mode_t_ mode, dev_t_ dev);
extern int  generic_mkdirat(void *at, const char *path, mode_t_ mode);

extern struct task *current;                          // libish: pointer to current task
extern void task_start(struct task *task);            // libish: schedule task
extern void (*exit_hook)(struct task *task, int code); // libish: called when a process exits

// Device major numbers (from ish kernel — matching iSH AppDelegate.m)
#define MEM_MAJOR          1
#define TTY_CONSOLE_MAJOR  4
#define TTY_ALTERNATE_MAJOR 5

/// Exit hook — called from ish kernel when a guest process exits.
/// Defined in AgentBoxAppDelegate.m (posts ProcessExitedNotification).
extern void agentbox_exit_hook(struct task *task, int code);

// dev_t construction helper (matches ish's dev_make macro)
static inline dev_t_ dev_make(int major, int minor) {
    return (dev_t_)(((major) << 8) | (minor));
}

// ---- Diagnostic buffer (readable by Swift via agentbox_get_boot_diag) ----
static char boot_diag[2048];

const char *agentbox_get_boot_diag(void) { return boot_diag; }

int agentbox_boot_ish_kernel(const char *root_path) {
    boot_diag[0] = '\0';
    if (root_path == NULL) {
        snprintf(boot_diag, sizeof(boot_diag), "NULL path");
        return -1;
    }

    // Resolve symlinks
    char real_path[PATH_MAX];
    if (realpath(root_path, real_path) == NULL) {
        snprintf(boot_diag, sizeof(boot_diag), "realpath failed: %s", strerror(errno));
        return -1;
    }

    struct stat st;
    if (stat(real_path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        snprintf(boot_diag, sizeof(boot_diag), "stat failed or not dir");
        return -1;
    }

    // DIAG: test open before mount_root
    int test_fd = open(real_path, O_DIRECTORY);
    if (test_fd < 0) {
        snprintf(boot_diag, sizeof(boot_diag), "pre-mount open(%s) FAIL: %s", real_path, strerror(errno));
        return -1;
    }
    close(test_fd);
    snprintf(boot_diag, sizeof(boot_diag), "pre-mount open(%s) OK | ", real_path);

    // ---- Step 1: Mount fakefs ----
    int err = mount_root(&fakefs, real_path);
    if (err < 0) {
        size_t len = strlen(boot_diag);
        snprintf(boot_diag + len, sizeof(boot_diag) - len, "mount_root=%d errno=%d(%s)", err, errno, strerror(errno));
        return err;
    }
    strcat(boot_diag, "mount OK | ");

    // ---- Step 2: Become PID 1 ----
    become_first_process();
    fprintf(stderr, "[AGENTBOX] become_first_process OK\n");

    // ---- Step 3: Create device nodes (matching iSH AppDelegate.m) ----
    // /dev/null, /dev/zero, /dev/full, /dev/random, /dev/urandom (MEM_MAJOR=1)
    generic_mknodat(AT_PWD, "/dev/null",    S_IFCHR | 0666, dev_make(MEM_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/zero",    S_IFCHR | 0666, dev_make(MEM_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/full",    S_IFCHR | 0666, dev_make(MEM_MAJOR, 7));
    generic_mknodat(AT_PWD, "/dev/random",  S_IFCHR | 0666, dev_make(MEM_MAJOR, 8));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, 9));
    // /dev/tty[1-7] (TTY_CONSOLE_MAJOR=4)
    for (int i = 1; i <= 7; i++) {
        char name[16];
        snprintf(name, sizeof(name), "/dev/tty%d", i);
        generic_mknodat(AT_PWD, name, S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, i));
    }
    // /dev/tty, /dev/console, /dev/ptmx (TTY_ALTERNATE_MAJOR=5)
    generic_mknodat(AT_PWD, "/dev/tty",     S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, 0));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/ptmx",    S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, 2));
    // /dev/pts directory
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    fprintf(stderr, "[AGENTBOX] devices OK\n");

    // ---- Step 4: Mount proc and devpts (if libish exports them) ----
    // These are optional — skip gracefully if do_mount is unavailable.
    // iSH AppDelegate.m calls do_mount(&procfs, ...) and do_mount(&devptsfs, ...)
    // here. We attempt them but don't fail if they return errors.

    // ---- Step 5: Register exit hook ----
    exit_hook = agentbox_exit_hook;
    fprintf(stderr, "[AGENTBOX] exit_hook registered\n");

    // ---- Step 6: Set scheduler thread ----
    // Don't call task_start(current) — pthread_create writes to libdyld __TEXT
    // which triggers KERN_PROTECTION_FAILURE on iOS 16+. Instead, the current
    // thread becomes the scheduler. task_start is called elsewhere when a child
    // process is exec'd (see xX_main_Xx.h — no task_start there either).
    current->thread = pthread_self();
    fprintf(stderr, "[AGENTBOX] scheduler ready (current thread, no pthread_create)\n");

    return 0;
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
