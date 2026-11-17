import AppKit
import SwiftUI

struct JournalView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var journal: DictationJournal
    @State private var query = ""
    @State private var selection: UUID?
    @State private var copiedID: UUID?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if journal.entries.isEmpty {
                placeholder("Everything you dictate appears here.", symbol: "text.bubble")
            } else if groups.isEmpty {
                placeholder("Nothing found.", symbol: "magnifyingglass")
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
                                row(entry).tag(entry.id).contextMenu { actions(entry) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if let selection { delete(selection) } }
            }
            if let entry = selection.flatMap(journal.entry) {
                Divider()
                detail(entry)
            }
            Divider()
            HStack {
                Text("Kept only on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(journal.entries.isEmpty || model.phase.busy)
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 420)
        .confirmationDialog("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { selection = nil; model.clearJournal() }
        } message: {
            Text("Texts and saved audio are deleted permanently.")
        }
    }

    // MARK: Rows

    private func row(_ entry: JournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.date, format: .dateTime.hour().minute()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                (entry.appName.map { Text(verbatim: $0) } ?? Text("Unknown App")).font(.caption).foregroundStyle(.secondary)
                if let text = entry.text {
                    Text(verbatim: text).lineLimit(2)
                } else {
                    Label { Text(verbatim: entry.detail ?? statusTitle(entry)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            rowAction(entry)
        }.padding(.vertical, 3)
    }

    @ViewBuilder private func rowAction(_ entry: JournalEntry) -> some View {
        if journal.transcribing.contains(entry.id) || isCurrentlySending(entry) {
            ProgressView().controlSize(.small)
        } else if let text = entry.text {
            Button { copy(text, entry.id) } label: {
                Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
            }.buttonStyle(.borderless).help(Text("Copy"))
        } else if canRetranscribe(entry) {
            Button("Transcribe") { model.retranscribe(entry.id) }.controlSize(.small)
        }
    }

    @ViewBuilder private func actions(_ entry: JournalEntry) -> some View {
        if let text = entry.text { Button("Copy") { copy(text, entry.id) } }
        if canRetranscribe(entry) { Button("Transcribe Again") { model.retranscribe(entry.id) } }
        if let audio = journal.audioURL(entry.id) { Button("Show Audio in Finder") { reveal(audio) } }
        Divider()
        Button("Delete", role: .destructive) { delete(entry.id) }
    }

    // MARK: Detail

    private func detail(_ entry: JournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: detailHeader(entry)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let text = entry.text { Button("Copy") { copy(text, entry.id) } }
                if canRetranscribe(entry) { Button("Transcribe Again") { model.retranscribe(entry.id) } }
                if let audio = journal.audioURL(entry.id) {
                    Button { reveal(audio) } label: { Image(systemName: "waveform") }.help(Text("Show Audio in Finder"))
                }
                Button("Delete") { delete(entry.id) }
            }.controlSize(.small)
            ScrollView {
                Text(verbatim: entry.text ?? (entry.detail ?? statusTitle(entry)))
                    .foregroundStyle(entry.text == nil ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 110)
        }.padding(14)
    }

    private func detailHeader(_ entry: JournalEntry) -> String {
        var parts = [entry.date.formatted(date: .long, time: .shortened)]
        if let app = entry.appName { parts.append(app) }
        if let seconds = entry.seconds { parts.append(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)) }
        if let model = entry.model { parts.append(model) }
        if entry.audioFile != nil {
            parts.append(String(localized: "audio saved"))
        } else if entry.text == nil {
            parts.append(String(localized: "audio not saved"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private func canRetranscribe(_ entry: JournalEntry) -> Bool {
        entry.status == .failed && entry.audioFile != nil && !journal.transcribing.contains(entry.id)
    }

    /// The current session is sending this entry's recording right now.
    private func isCurrentlySending(_ entry: JournalEntry) -> Bool {
        entry.status == .pending && model.phase.busy
    }

    private func statusTitle(_ entry: JournalEntry) -> String {
        switch entry.status {
        case .pending: return String(localized: "Transcribing…")
        case .failed: return String(localized: "Not transcribed")
        case .delivered: return ""
        }
    }

    private func copy(_ text: String, _ id: UUID) {
        model.copy(text)
        copiedID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        model.deleteJournalEntry(id)
    }

    private func placeholder(_ text: LocalizedStringKey, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Group { let title: String; let entries: [JournalEntry] }

    private var groups: [Group] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? journal.entries : journal.entries.filter { entry in
            [entry.text, entry.appName, entry.detail].contains { $0?.localizedCaseInsensitiveContains(needle) == true }
        }
        let calendar = Calendar.current
        var result: [Group] = []
        for entry in matching {
            let title = calendar.isDateInToday(entry.date) ? String(localized: "Today")
                : calendar.isDateInYesterday(entry.date) ? String(localized: "Yesterday")
                : entry.date.formatted(.dateTime.day().month(.wide).year())
            if result.last?.title == title {
                result[result.count - 1] = Group(title: title, entries: result[result.count - 1].entries + [entry])
            } else {
                result.append(Group(title: title, entries: [entry]))
            }
        }
        return result
    }

}
