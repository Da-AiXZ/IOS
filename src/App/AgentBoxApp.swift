import SwiftUI

/// AgentBox — iOS AI Agent 应用入口。
///
/// 启动时自动初始化 ish-arm64 Linux 引擎（若 rootfs 可用）。
/// 引擎初始化在后台 .task 中执行，不阻塞 UI。
@main
struct AgentBoxApp: App {

    // MARK: - Engine Reference

    /// 全局引擎实例，注入到视图层级。
    @StateObject private var engine = ISHEngine.shared

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .task {
                    await initializeEngine()
                }
        }
    }

    // MARK: - Engine Initialization

    /// 在 App 启动时异步初始化 ish 引擎。
    ///
    /// 引擎初始化分为三个阶段：
    /// 1. 解压 Alpine aarch64 rootfs（首次启动）
    /// 2. 启动 ish Linux 内核
    /// 3. 就绪验证（echo 'engine-ready'）
    ///
    /// 若 rootfs 资源未捆绑（开发阶段），跳过初始化，
    /// 其他模块（SpawnRoot、FileSystemAccess）仍可独立使用。
    private func initializeEngine() async {
        // 查找捆绑的 Alpine rootfs
        guard let rootfsURL = Bundle.main.url(
            forResource: "alpine-aarch64",
            withExtension: "tar.gz"
        ) else {
            print("[AgentBoxApp] ⚠️ alpine-aarch64.tar.gz 未找到，跳过引擎初始化")
            print("[AgentBoxApp] SpawnRoot / FileSystemAccess 仍可正常使用")
            return
        }

        print("[AgentBoxApp] 开始初始化 ish-arm64 引擎...")

        do {
            try await engine.initialize(rootfsURL: rootfsURL)
            print("[AgentBoxApp] ✅ ish-arm64 引擎初始化成功")
        } catch {
            print("[AgentBoxApp] ❌ 引擎初始化失败: \(error.localizedDescription)")
            // 错误已反映在 engine.state 中，ContentView 会展示
        }
    }
}
