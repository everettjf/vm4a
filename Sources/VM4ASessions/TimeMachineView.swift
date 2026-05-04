import SwiftUI
import VM4ACore

struct TimeMachineView: View {
    @EnvironmentObject var model: SessionsViewModel

    var body: some View {
        NavigationSplitView {
            SessionsListView()
        } detail: {
            if let id = model.selectedID, let descriptor = model.sessions.first(where: { $0.id == id }) {
                SessionDetailView(descriptor: descriptor)
            } else {
                ContentUnavailableMessage(
                    title: "Select a session",
                    subtitle: "Pick a recorded session in the sidebar to inspect its events.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
    }
}

struct SessionsListView: View {
    @EnvironmentObject var model: SessionsViewModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { newID in
                model.selectedID = newID
                if let id = newID, let descriptor = model.sessions.first(where: { $0.id == id }) {
                    model.loadEvents(for: descriptor)
                }
            }
        )) {
            if model.sessions.isEmpty {
                Text("No sessions yet.\nRun an agent command with --session <id>.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            }
            ForEach(model.sessions, id: \.id) { session in
                SessionRow(session: session).tag(session.id as String?)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionDescriptor

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.id)
                .font(.headline)
                .lineLimit(1)
            Text(Self.formatter.string(from: session.modified))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(byteCount(session.bytes))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func byteCount(_ n: Int) -> String {
        let kb = Double(n) / 1024
        if kb < 1 { return "\(n) B" }
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

struct SessionDetailView: View {
    let descriptor: SessionDescriptor
    @EnvironmentObject var model: SessionsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                if model.events.isEmpty {
                    Text("Session has no events yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(model.events, id: \.seq) { event in
                        EventRow(event: event)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(descriptor.id)
        .navigationSubtitle(descriptor.bundlePath ?? "(home)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(descriptor.id).font(.title2).bold()
            Text(descriptor.file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                statBadge(label: "events", value: "\(model.events.count)")
                statBadge(label: "bytes", value: "\(descriptor.bytes)")
                if let firstSuccess = model.events.first?.success {
                    statBadge(label: "first event", value: firstSuccess ? "ok" : "failed", color: firstSuccess ? .green : .red)
                }
            }
        }
    }

    private func statBadge(label: String, value: String, color: Color = .blue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08))
        .cornerRadius(4)
    }
}

struct EventRow: View {
    let event: SessionEvent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: event.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(event.success ? Color.green : Color.red)
                    .font(.title2)
                Text("#\(event.seq)").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.kind).font(.headline.monospaced())
                    Spacer()
                    Text(Self.timeFormatter.string(from: event.timestamp))
                        .font(.caption).foregroundStyle(.secondary)
                    if let ms = event.durationMs {
                        Text("\(ms)ms").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary).font(.callout)
                }
                if let argsText = pretty(event.args) {
                    DisclosureGroup("args") {
                        Text(argsText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let outcomeText = pretty(event.outcome) {
                    DisclosureGroup("outcome") {
                        Text(outcomeText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    private func pretty(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty, s != "null", s != "{}" else {
            return nil
        }
        return s
    }
}

struct ContentUnavailableMessage: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
