import SwiftUI
import SwiftData

@main
struct AgentBoxApp: App {
    let container: ModelContainer

    init() {
        do {
            let schema = Schema([
                Conversation.self,
                Message.self,
                AgentSession.self,
                SkillConfig.self,
                LLMConfiguration.self,
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
