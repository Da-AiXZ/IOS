import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .chat

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                PlaceholderView(title: "Chat", icon: "bubble.left.and.bubble.right")
                    .navigationTitle("AgentBox")
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            .tag(Tab.chat)

            NavigationStack {
                PlaceholderView(title: "Terminal", icon: "terminal")
                    .navigationTitle("Terminal")
            }
            .tabItem { Label("Terminal", systemImage: "terminal") }
            .tag(Tab.terminal)

            NavigationStack {
                PlaceholderView(title: "Files", icon: "folder")
                    .navigationTitle("Files")
            }
            .tabItem { Label("Files", systemImage: "folder") }
            .tag(Tab.files)

            NavigationStack {
                PlaceholderView(title: "Browser", icon: "safari")
                    .navigationTitle("Browser")
            }
            .tabItem { Label("Browser", systemImage: "safari") }
            .tag(Tab.browser)

            NavigationStack {
                PlaceholderView(title: "Settings", icon: "gear")
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
    }
}

enum Tab: Hashable {
    case chat, terminal, files, browser, settings
}

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

#Preview {
    ContentView()
}
