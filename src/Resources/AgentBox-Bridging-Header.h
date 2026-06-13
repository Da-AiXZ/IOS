// AgentBox Bridging Header
// Phase 2: ish-arm64 C/Obj-C bridge + persona management
// Target: iOS 16.6.1, ARM64 only, TrollStore 2 signed

#ifndef AgentBox_Bridging_Header_h
#define AgentBox_Bridging_Header_h

// MARK: - System Headers (POSIX)
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <copyfile.h>

// MARK: - ish-arm64 Core Headers
// These paths assume libish headers are in the Xcode header search paths.
// In practice, they're resolved via the libish Meson build output or
// a header-only wrapper target in the Xcode project.

// Kernel initialization
#include "kernel/init.h"          // actuate_kernel()

// File system layer
#include "fs/real.h"              // realfs bind mount, realfs_open, etc.
#include "fs/path.h"              // path resolution utilities

// Sync primitive helpers (used by AppDelegate.m)
#include "kernel/task.h"          // current, task struct

// MARK: - ish-arm64 Obj-C API Headers
// These headers are part of the ish iOS app layer, repurposed for AgentBox.

#import "ISHShellExecutor.h"      // ISHShellExecutor + ISHShellExecutionResult
#import "LinuxInterop.h"          // LinuxInterop session bridge
#import "AppGroup.h"              // AppGroup container utilities
#import "CurrentRoot.h"           // CurrentRoot path management
#import "Roots.h"                 // Roots path registry

// MARK: - Process Lifecycle Notifications
// Defined in ISHShellExecutor.m; observed by ShellBridge.
extern NSString *const ProcessExitedNotification;

// MARK: - AgentBox C Function Declarations (PersonaSpawn.c)

/// Allocate a root persona (UID=0) via libpersona.dylib.
/// @param out_persona_id Pointer to receive the allocated persona ID.
/// @return 0 on success, -1 on failure (check errno).
int agentbox_persona_alloc_root(uint32_t *out_persona_id);

/// Deallocate a previously allocated persona.
/// @param persona_id The persona ID to release.
/// @return 0 on success, -1 on failure.
int agentbox_persona_dealloc(uint32_t persona_id);

/// Spawn a child process with a root persona.
/// Uses posix_spawn + posix_spawnattr_set_persona_np.
///
/// @param persona_id The root persona ID from agentbox_persona_alloc_root().
/// @param binary_path Absolute path to the executable (e.g., "/bin/sh").
/// @param argv NULL-terminated argument array (argv[0] = program name).
/// @param envp NULL-terminated environment array, or NULL to inherit.
/// @param out_stdout_fd Pointer to receive the child's stdout read-end fd.
/// @param out_stderr_fd Pointer to receive the child's stderr read-end fd.
/// @param out_pid Pointer to receive the child's PID.
/// @return 0 on success, -1 on failure.
int agentbox_spawn_with_persona(
    uint32_t persona_id,
    const char *binary_path,
    char *const argv[],
    char *const envp[],
    int *out_stdout_fd,
    int *out_stderr_fd,
    pid_t *out_pid
);

/// Simplified spawn: alloc persona, spawn /bin/sh -c <command>, wait, return result.
///
/// @param command The shell command string to execute.
/// @param out_stdout Pointer to receive malloc'd stdout string (caller must free).
/// @param out_stderr Pointer to receive malloc'd stderr string (caller must free).
/// @param out_exit_code Pointer to receive the exit code.
/// @return 0 on success, -1 on spawn/persona failure.
int agentbox_spawn_root_simple(
    const char *command,
    char **out_stdout,
    char **out_stderr,
    int *out_exit_code
);

/// Fork-based fallback for when persona mechanism is unavailable.
/// Uses fork() + setuid(0) + execve() in the child.
///
/// @param binary_path Absolute path to the executable.
/// @param argv NULL-terminated argument array.
/// @param envp NULL-terminated environment array, or NULL to inherit.
/// @param out_stdout_fd Pointer to receive stdout read-end fd.
/// @param out_stderr_fd Pointer to receive stderr read-end fd.
/// @param out_pid Pointer to receive child PID.
/// @return 0 on success, -1 on failure.
int agentbox_fork_root_spawn(
    const char *binary_path,
    char *const argv[],
    char *const envp[],
    int *out_stdout_fd,
    int *out_stderr_fd,
    pid_t *out_pid
);

// MARK: - ish Kernel Boot Bridge
// Called by ISHAppShim.swift → ISHEngine.swift to boot the Linux kernel.

/// Boot the ish Linux kernel with the given root filesystem path.
/// Wraps actuate_kernel() from kernel/init.h.
/// @param root_path Null-terminated C string: path to extracted rootfs.
/// @return 0 on success, non-zero error code on failure.
int agentbox_boot_ish_kernel(const char *root_path);

// MARK: - waitpid Macro Wrappers (Swift can't call C macros)

int agentbox_wifexited(int status);
int agentbox_wexitstatus(int status);
int agentbox_wifsignaled(int status);
int agentbox_wtermsig(int status);

#endif /* AgentBox_Bridging_Header_h */
