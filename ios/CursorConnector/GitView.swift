import SwiftUI

/// Git tab: list of changes (like Cursor), Generate commit message, Commit, and Push.
struct GitView: View {
    let projectPath: String
    let host: String
    let port: Int

    @State private var status: CompanionAPI.GitStatusResponse?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var commitMessage = ""
    @State private var generating = false
    @State private var committing = false
    @State private var pushing = false
    @State private var actionMessage: String?
    @State private var actionError: String?
    @State private var selectedChange: CompanionAPI.GitChangeEntry?
    @State private var actionsResponse: CompanionAPI.GitHubActionsResponse?
    @State private var actionsLoading = false
    @State private var actionsError: String?
    @State private var actionsSectionExpanded = false

    private var hasChanges: Bool { status.map { !$0.changes.isEmpty } ?? false }
    private var mostRecentRun: CompanionAPI.GitHubActionsRun? { actionsResponse?.runs.first }

    var body: some View {
        List {
            Section {
                if let st = status {
                    HStack {
                        Label(st.branch, systemImage: "branch")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                }
                if loading && status == nil {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = errorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Branch")
            }

            Section {
                HStack(spacing: 8) {
                    Text("GitHub Actions")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let run = mostRecentRun {
                        Image(systemName: iconForActionsConclusion(run.conclusion, status: run.status))
                            .foregroundStyle(colorForActionsConclusion(run.conclusion, status: run.status))
                            .font(.caption)
                    } else if actionsLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { actionsSectionExpanded.toggle() }
                    } label: {
                        Image(systemName: actionsSectionExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { actionsSectionExpanded.toggle() }
                }

                if actionsSectionExpanded {
                    HStack {
                        Text("CI workflow runs")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            Task { await loadGitHubActions() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.subheadline)
                        }
                        .disabled(actionsLoading)
                    }
                    if actionsLoading && actionsResponse == nil {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    if let err = actionsError ?? actionsResponse?.error, !err.isEmpty {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    if let runs = actionsResponse?.runs, !runs.isEmpty {
                        ForEach(runs) { run in
                            Button {
                                if let url = URL(string: run.htmlUrl) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: iconForActionsConclusion(run.conclusion, status: run.status))
                                        .foregroundStyle(colorForActionsConclusion(run.conclusion, status: run.status))
                                        .font(.body)
                                        .frame(width: 24, alignment: .center)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(run.headBranch) · \(relativeTime(run.createdAt))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else if actionsResponse != nil && actionsError == nil && (actionsResponse?.error?.isEmpty ?? true) {
                        Text("No workflow runs")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section {
                ForEach(status?.changes ?? []) { change in
                    Button {
                        selectedChange = change
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: iconForStatus(change.status))
                                .foregroundStyle(colorForStatus(change.status))
                                .font(.body)
                                .frame(width: 24, alignment: .center)
                            Text(change.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            selectedChange = change
                        } label: {
                            Label("View diff", systemImage: "doc.diff")
                        }
                    }
                }
            } header: {
                Text("Changes")
            } footer: {
                if (status?.changes.isEmpty ?? true) && !loading {
                    Text("No changes. Pull to refresh.")
                }
            }

            Section {
                TextField("Commit message", text: $commitMessage, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.sentences)

                Button {
                    Task { await generateMessage() }
                } label: {
                    HStack {
                        if generating {
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        Label(generating ? "Generating…" : "Generate", systemImage: "wand.and.stars")
                    }
                }
                .disabled(generating || !hasChanges)

                Button {
                    Task { await commit() }
                } label: {
                    HStack {
                        if committing {
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        Label(committing ? "Committing…" : "Commit", systemImage: "checkmark.circle")
                    }
                }
                .disabled(committing || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await push() }
                } label: {
                    HStack {
                        if pushing {
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                        Label(pushing ? "Pushing…" : "Push", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(pushing)
            } header: {
                Text("Commit")
            }

            if let msg = actionMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            if let err = actionError {
                Section {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Git")
        .navigationDestination(item: $selectedChange) { change in
            GitDiffLoaderView(projectPath: projectPath, host: host, port: port, filePath: change.path)
        }
        .task {
            await loadStatus()
            await loadGitHubActions()
        }
        .refreshable {
            await loadStatus()
            await loadGitHubActions()
        }
    }

    private func loadGitHubActions() async {
        actionsLoading = true
        actionsError = nil
        defer { actionsLoading = false }
        do {
            let response = try await CompanionAPI.fetchGitHubActions(path: projectPath, host: host, port: port)
            await MainActor.run {
                actionsResponse = response
                if let err = response.error, !err.isEmpty { actionsError = err }
            }
        } catch {
            await MainActor.run {
                actionsError = error.localizedDescription
                actionsResponse = nil
            }
        }
    }

    private func iconForActionsConclusion(_ conclusion: String?, status: String) -> String {
        if status == "in_progress" || status == "queued" {
            return "clock.arrow.circlepath"
        }
        switch conclusion?.lowercased() {
        case "success": return "checkmark.circle.fill"
        case "failure", "cancelled": return "xmark.circle.fill"
        case "skipped": return "forward.circle.fill"
        default: return "circle.dashed"
        }
    }

    private func colorForActionsConclusion(_ conclusion: String?, status: String) -> Color {
        if status == "in_progress" || status == "queued" { return .orange }
        switch conclusion?.lowercased() {
        case "success": return .green
        case "failure", "cancelled": return .red
        case "skipped": return .secondary
        default: return .secondary
        }
    }

    private func relativeTime(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: iso8601) == nil {
            formatter.formatOptions = [.withInternetDateTime]
        }
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func iconForStatus(_ status: String) -> String {
        let s = status.trimmingCharacters(in: .whitespaces)
        if s == "??" { return "plus.circle" }
        if s.contains("M") || s.contains("A") { return "pencil.circle" }
        if s.contains("D") { return "minus.circle" }
        if s.contains("U") { return "arrow.triangle.merge" }
        return "doc"
    }

    private func colorForStatus(_ status: String) -> Color {
        let s = status.trimmingCharacters(in: .whitespaces)
        if s == "??" { return .orange }
        if s.contains("M") || s.contains("A") { return .blue }
        if s.contains("D") { return .red }
        return .secondary
    }

    private func loadStatus() async {
        loading = true
        errorMessage = nil
        actionMessage = nil
        actionError = nil
        defer { loading = false }
        do {
            let st = try await CompanionAPI.fetchGitStatus(path: projectPath, host: host, port: port)
            await MainActor.run { status = st }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                status = nil
            }
        }
    }

    private func generateMessage() async {
        generating = true
        actionMessage = nil
        actionError = nil
        defer { generating = false }
        do {
            let message = try await CompanionAPI.generateCommitMessage(path: projectPath, host: host, port: port)
            await MainActor.run { commitMessage = message }
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }

    private func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        committing = true
        actionMessage = nil
        actionError = nil
        defer { committing = false }
        do {
            let result = try await CompanionAPI.gitCommit(path: projectPath, message: message, host: host, port: port)
            await MainActor.run {
                if result.success {
                    commitMessage = ""
                    actionMessage = "Committed successfully."
                    actionError = nil
                } else {
                    actionError = result.error.isEmpty ? result.output : result.error
                }
            }
            if result.success {
                await loadStatus()
            }
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }

    private func push() async {
        pushing = true
        actionMessage = nil
        actionError = nil
        defer { pushing = false }
        do {
            let result = try await CompanionAPI.gitPush(path: projectPath, host: host, port: port)
            await MainActor.run {
                if result.success {
                    actionMessage = "Pushed successfully."
                    actionError = nil
                } else {
                    actionError = result.error.isEmpty ? result.output : result.error
                }
            }
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack {
        GitView(projectPath: "/tmp", host: "localhost", port: 9283)
    }
}
