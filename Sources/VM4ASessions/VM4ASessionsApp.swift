import SwiftUI
import VM4ACore

@main
struct VM4ASessionsApp: App {
    @StateObject private var model = SessionsViewModel()

    var body: some Scene {
        WindowGroup("VM4A — Time Machine") {
            TimeMachineView()
                .environmentObject(model)
                .onAppear { model.refresh() }
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class SessionsViewModel: ObservableObject {
    @Published var sessions: [SessionDescriptor] = []
    @Published var selectedID: String?
    @Published var events: [SessionEvent] = []

    func refresh() {
        sessions = SessionStore.discoverSessions(bundlePath: nil)
        if let selectedID, !sessions.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            self.events = []
        }
    }

    func loadEvents(for descriptor: SessionDescriptor) {
        do {
            events = try SessionStore.read(id: descriptor.id, bundlePath: descriptor.bundlePath)
        } catch {
            events = []
        }
    }
}
