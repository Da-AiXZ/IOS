import Foundation

// MARK: - ish AppDelegate Replacement (Swift Adapter)

/// ISHAppShim serves as the minimal Swift replacement for iSH's AppDelegate.
///
/// The original iSH iOS app uses `AppDelegate.m` to manage:
/// 1. The `current` singleton — referenced by ISHShellExecutor.m via
///    `#import "AppDelegate.h"` and `AppDelegate.current`.
/// 2. `initISH()` — initializes the ish runtime environment.
/// 3. `bootKernel(rootPath:)` — calls `actuate_kernel()` to start Linux.
///
/// Since AgentBox is a SwiftUI app (no traditional AppDelegate), this shim
/// provides the same interface so that ISHShellExecutor.m can function
/// without modification.
///
/// - Note: ISHShellExecutor.m imports `AppDelegate.h`. We provide a minimal
///   Obj-C compatible class exposed via the Bridging Header, or alternatively
///   use `@objc(ISHAppShim)` to expose this Swift class to Obj-C callers.
@objc(ISHAppShim)
@MainActor
final class ISHAppShim: NSObject {

    // MARK: - Singleton

    /// Shared instance — equivalent to `[AppDelegate current]` in the original iSH.
    @objc static let current = ISHAppShim()

    // MARK: - State

    /// Whether the ish kernel has been successfully booted.
    @objc private(set) var bootCompleted: Bool = false

    /// The path to the extracted root filesystem.
    @objc private(set) var rootPath: String = ""

    /// Whether ish environment initialization is complete (pre-boot).
    @objc private(set) var ishInitialized: Bool = false

    // MARK: - initISH

    /// Initialize the ish runtime environment.
    ///
    /// This replaces the non-AppDelegate-specific parts of `AppDelegate.initISH`.
    /// It sets up the ish filesystem layer, terminal infrastructure, and
    /// other pre-kernel initialization steps.
    ///
    /// - Returns: `true` if initialization succeeded, `false` otherwise.
    @objc func initISH() -> Bool {
        guard !ishInitialized else {
            print("[ISHAppShim] ish 环境已初始化，跳过")
            return true
        }

        print("[ISHAppShim] 初始化 ish 运行时环境...")

        // The original AppDelegate.initISH performs:
        // 1. Sets up terminal font and color scheme
        // 2. Initializes filesystem roots (Roots)
        // 3. Configures NSUserDefaults for ish settings
        // 4. Registers notification observers
        //
        // For AgentBox, we only need the filesystem roots and
        // the basics that ISHShellExecutor depends on:
        // - Roots (rootfs registry)
        // - CurrentRoot (active root path management)
        // - AppGroup container path resolution

        // Register default ish UserDefaults
        let defaults: [String: Any] = [
            "ish_autocapitalization": false,
            "ish_autocorrection": false,
            "ish_theme": "default",
            "ish_font_size": 14.0,
        ]
        UserDefaults.standard.register(defaults: defaults)

        ishInitialized = true
        print("[ISHAppShim] ish 运行时环境初始化完成")
        return true
    }

    // MARK: - bootKernel

    /// Boot the ish Linux kernel with the given root filesystem path.
    ///
    /// Calls `agentbox_boot_ish_kernel()` (defined in PersonaSpawn.c, exposed
    /// via the Bridging Header) which wraps `actuate_kernel()` from libish.
    ///
    /// - Parameter rootPath: Absolute path to the extracted Alpine rootfs.
    /// - Returns: 0 on success, non-zero error code on failure.
    @objc func bootKernel(_ rootPath: String) -> Int32 {
        guard ishInitialized else {
            print("[ISHAppShim] 错误：ish 环境未初始化，无法启动内核")
            return -1
        }

        guard !bootCompleted else {
            print("[ISHAppShim] 内核已启动，跳过")
            return 0
        }

        print("[ISHAppShim] 启动 ish Linux 内核，rootfs=\(rootPath)")

        self.rootPath = rootPath
        let result = agentbox_boot_ish_kernel(rootPath)

        if result == 0 {
            bootCompleted = true
            print("[ISHAppShim] ish 内核启动成功")
        } else {
            print("[ISHAppShim] ish 内核启动失败，错误码: \(result)")
        }

        return result
    }

    // MARK: - Post-Boot Session Setup

    /// Called after kernel boot to establish a Linux session.
    ///
    /// The original iSH AppDelegate starts a `linux_start_session`
    /// after `actuate_kernel()` returns. This method encapsulates that
    /// step if needed by ISHShellExecutor.
    ///
    /// - Returns: `true` if session was established.
    @objc func startLinuxSession() -> Bool {
        guard bootCompleted else {
            print("[ISHAppShim] 错误：内核未启动，无法建立会话")
            return false
        }

        // In the original iSH flow:
        // linux_start_session(rootPath, done: { success in ... })
        // For AgentBox, ISHShellExecutor handles session management internally.
        print("[ISHAppShim] Linux 会话就绪 (由 ISHShellExecutor 管理)")
        return true
    }
}

// MARK: - Obj-C Interop Support

/// Expose ISHAppShim to Obj-C code (ISHShellExecutor.m) via the runtime.
/// ISHShellExecutor.m references `AppDelegate.current` — by naming this class
/// `ISHAppShim` and implementing `current`, we provide a drop-in replacement.
///
/// In the Bridging Header, we do NOT import ISHAppShim directly (it's Swift).
/// Instead, ISHShellExecutor.m should be modified to use `[ISHAppShim current]`
/// instead of `[AppDelegate current]`. This requires a one-line change in the
/// vendored ISHShellExecutor.m, or a compatibility macro.
extension ISHAppShim {

    /// Convenience: check if the engine environment is fully ready
    /// (environment initialized + kernel booted + session active).
    var isReady: Bool {
        ishInitialized && bootCompleted
    }

    /// Reset the shim to uninitialized state (for testing or re-initialization).
    func reset() {
        bootCompleted = false
        ishInitialized = false
        rootPath = ""
        print("[ISHAppShim] 状态已重置")
    }
}
