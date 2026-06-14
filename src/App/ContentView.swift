import SwiftUI

// MARK: - ContentView

/// AgentBox 主界面 — 多 Tab 布局。
///
/// Tab 结构：
/// - **Chat**: Agent 对话界面（Phase 3+）
/// - **Terminal**: ish 引擎状态 + 快速验证面板（Phase 2）
/// - **Files**: 文件浏览器（Phase 3+）
/// - **Browser**: 内嵌浏览器（Phase 3+）
/// - **Settings**: 设置（Phase 1 占位，Phase 3+ 完善）
struct ContentView: View {

    /// 当前选中的 Tab。
    @State private var selectedTab: Tab = .chat

    /// 引擎引用（从父视图注入）。
    @EnvironmentObject var engine: ISHEngine

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Chat
            NavigationStack {
                ChatPlaceholderView()
                    .navigationTitle("AgentBox")
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .tag(Tab.chat)

            // Tab 2: Terminal / Engine Status
            NavigationStack {
                TerminalStatusView(engine: engine)
                    .navigationTitle("Terminal")
            }
            .tabItem {
                Label("Terminal", systemImage: "terminal")
            }
            .tag(Tab.terminal)

            // Tab 3: Files
            NavigationStack {
                PlaceholderView(title: "Files", icon: "folder")
                    .navigationTitle("Files")
            }
            .tabItem {
                Label("Files", systemImage: "folder")
            }
            .tag(Tab.files)

            // Tab 4: Browser
            NavigationStack {
                PlaceholderView(title: "Browser", icon: "safari")
                    .navigationTitle("Browser")
            }
            .tabItem {
                Label("Browser", systemImage: "safari")
            }
            .tag(Tab.browser)

            // Tab 5: Settings
            NavigationStack {
                PlaceholderView(title: "Settings", icon: "gear")
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(Tab.settings)
        }
    }
}

// MARK: - Tab Enum

/// 主 Tab 枚举。
enum Tab: Hashable {
    case chat
    case terminal
    case files
    case browser
    case settings
}

// MARK: - Placeholder View

/// 通用占位视图（用于尚未实现的 Tab）。
struct PlaceholderView: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Chat Placeholder

/// Chat Tab 的占位视图。
private struct ChatPlaceholderView: View {
    var body: some View {
        PlaceholderView(title: "Chat", icon: "bubble.left.and.bubble.right")
    }
}

// MARK: - Terminal / Engine Status View

/// Terminal Tab — 展示 ish 引擎状态 + 快速验证功能。
///
/// - 若引擎未初始化：显示状态和初始化过程
/// - 若引擎就绪：显示 "Engine Ready" + 简单命令输入框
/// - 若引擎错误：显示错误信息和重试按钮
struct TerminalStatusView: View {
    @ObservedObject var engine: ISHEngine

    /// 快速验证命令输入。
    @State private var testCommand: String = "echo 'Hello from Linux'"

    /// 命令执行输出。
    @State private var testOutput: String = ""

    /// 是否正在执行测试命令。
    @State private var isRunningTest: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Engine Status Card
                engineStatusCard

                // Quick Test Panel (only when ready)
                if engine.isInitialized {
                    quickTestPanel
                }

                // SpawnRoot independent test (always available)
                spawnRootTestPanel

                Spacer()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Engine Status Card

    private var engineStatusCard: some View {
        VStack(spacing: 12) {
            // Status Icon
            Image(systemName: statusIcon)
                .font(.system(size: 40))
                .foregroundStyle(statusColor)

            // Status Text
            Text(statusTitle)
                .font(.headline)
                .foregroundStyle(statusColor)

            // Detail
            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Progress indicator during init
            if case .extracting = engine.state {
                ProgressView()
                    .padding(.top, 4)
            }
            if case .booting = engine.state {
                ProgressView()
                    .padding(.top, 4)
            }

            // Error: show retry (retry is implicit — re-launch the app or
            // call reinitialize via a button)
            if case .error = engine.state {
                Text("请检查 rootfs 资源是否完整，然后重新启动 App。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Quick Test Panel

    private var quickTestPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("快速验证", systemImage: "play.circle")
                .font(.headline)

            TextField("输入命令", text: $testCommand)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .autocapitalization(.none)

            HStack {
                Button(action: runTestCommand) {
                    Label(
                        isRunningTest ? "执行中..." : "执行",
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningTest || testCommand.isEmpty)

                Button(action: { testOutput = "" }) {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(testOutput.isEmpty)
            }

            if !testOutput.isEmpty {
                ScrollView {
                    Text(testOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - SpawnRoot Test Panel

    private var spawnRootTestPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SpawnRoot (iOS 原生)", systemImage: "cpu")
                .font(.headline)

            Text("SpawnRoot 和 FileSystemAccess 不依赖 ish 引擎，可独立使用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: testSpawnRootWhoami) {
                    Label("whoami", systemImage: "person.badge.key")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: testFileSystemAccess) {
                    Label("文件 IO", systemImage: "doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            // Show test output BELOW the buttons, always visible
            if !testOutput.isEmpty {
                ScrollView {
                    Text(testOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: { testOutput = "" }) {
                    Label("清空输出", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Computed Properties

    private var statusIcon: String {
        switch engine.state {
        case .uninitialized:    return "circle"
        case .extracting:       return "arrow.down.circle"
        case .booting:          return "power"
        case .ready:            return "checkmark.circle.fill"
        case .error:            return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .uninitialized:    return .secondary
        case .extracting:       return .orange
        case .booting:          return .blue
        case .ready:            return .green
        case .error:            return .red
        }
    }

    private var statusTitle: String {
        switch engine.state {
        case .uninitialized:    return "引擎未初始化"
        case .extracting:       return "正在准备 RootFS..."
        case .booting:          return "正在启动内核..."
        case .ready:            return "Engine Ready"
        case .error:            return "初始化失败"
        }
    }

    private var statusDetail: String {
        let rootfsURL = URL(fileURLWithPath: "/tmp/ish-rootfs/data", isDirectory: true)
        let bbPath = rootfsURL.appendingPathComponent("bin/busybox").path
        let shPath = rootfsURL.appendingPathComponent("bin/sh").path
        let bbExists = FileManager.default.fileExists(atPath: bbPath)
        let shExists = FileManager.default.fileExists(atPath: shPath)
        
        let debugInfo = """
        ─────────────────────
        busybox: \(bbExists ? "✅" : "❌")  sh: \(shExists ? "✅" : "❌")
        rootfs 路径: \(rootfsURL.path)
        isInitialized: \(engine.isInitialized)
        当前状态: \(engine.state.description)
        ─────────────────────
        """
        
        switch engine.state {
        case .uninitialized:
            return "等待引擎初始化...\n\(debugInfo)"
        case .extracting(let progress):
            return "\(progress)\n\(debugInfo)"
        case .booting:
            return "正在启动 ish Linux 内核...\n\(debugInfo)"
        case .ready:
            return "✅ 引擎就绪，可执行 shell 命令。\n\(debugInfo)"
        case .error(let msg):
            return "❌ \(msg)\n\(debugInfo)"
        }
    }

    // MARK: - Actions

    /// 在 Linux guest 中执行测试命令。
    private func runTestCommand() {
        guard !testCommand.isEmpty else { return }
        isRunningTest = true
        testOutput = ""

        Task {
            defer { isRunningTest = false }

            do {
                let result = try await ISHShellBridge.shared.execute(testCommand)
                let output = """
                === 命令: \(testCommand) ===
                退出码: \(result.exitCode)
                耗时: \(String(format: "%.3f", result.duration))s
                --- stdout ---
                \(result.stdout)
                --- stderr ---
                \(result.stderr)
                === 结束 ===
                """
                testOutput = output
            } catch {
                testOutput = "执行失败: \(error.localizedDescription)"
            }
        }
    }

    /// 测试 SpawnRoot.execute("whoami") → 预期输出 "root"。
    private func testSpawnRootWhoami() {
        Task {
            do {
                let result = try SpawnRoot.execute("whoami")
                testOutput = """
                === SpawnRoot: whoami ===
                退出码: \(result.exitCode)
                输出: \(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
                PID: \(result.pid)
                === 结束 ===
                """
            } catch {
                testOutput = "SpawnRoot 测试失败: \(error.localizedDescription)"
            }
        }
    }

    /// 测试 FileSystemAccess 写入/读取 /tmp/agentbox-test.txt。
    private func testFileSystemAccess() {
        do {
            let testPath = "/tmp/agentbox-test.txt"
            let testData = "Hello from AgentBox - \(Date())".data(using: .utf8)!

            try FileSystemAccess.writeFile(at: testPath, data: testData)
            let readData = try FileSystemAccess.readFile(at: testPath)
            let readString = String(data: readData, encoding: .utf8) ?? "解码失败"

            // Clean up
            try? FileSystemAccess.deleteFile(at: testPath)

            testOutput = """
            === FileSystemAccess: /tmp/agentbox-test.txt ===
            写入: 成功 (\(testData.count) 字节)
            读取: \(readString)
            清理: 已删除
            === 结束 ===
            """
        } catch {
            testOutput = "FileSystemAccess 测试失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ISHEngine.shared)
}
