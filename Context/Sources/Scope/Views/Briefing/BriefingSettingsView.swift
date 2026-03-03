import SwiftUI

struct BriefingSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var newFeedURL = ""
    @State private var newSubreddit = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Staleness
                GroupBox("Auto-Refresh") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Refresh when older than \(Int(settings.briefingStalenessHours))h")
                                .font(.system(size: 12))
                            Slider(
                                value: $settings.briefingStalenessHours,
                                in: 1...24,
                                step: 1
                            )
                        }
                        Text("Briefing regenerates automatically on app launch if the latest one is older than this threshold.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                }

                // RSS Feeds
                GroupBox("RSS Feeds") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.briefingRSSFeeds, id: \.self) { feed in
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Text(feedDisplayName(feed))
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    settings.briefingRSSFeeds.removeAll { $0 == feed }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        HStack(spacing: 6) {
                            TextField("https://example.com/feed.xml", text: $newFeedURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))

                            Button("Add") {
                                let url = newFeedURL.trimmingCharacters(in: .whitespaces)
                                guard !url.isEmpty, !settings.briefingRSSFeeds.contains(url) else { return }
                                settings.briefingRSSFeeds.append(url)
                                newFeedURL = ""
                            }
                            .font(.system(size: 11))
                            .disabled(newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(8)
                }

                // Subreddits
                GroupBox("Reddit Subreddits") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.briefingSubreddits, id: \.self) { sub in
                            HStack {
                                Text("r/\(sub)")
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.briefingSubreddits.removeAll { $0 == sub }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        HStack(spacing: 6) {
                            TextField("subreddit name (no r/)", text: $newSubreddit)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))

                            Button("Add") {
                                let sub = newSubreddit.trimmingCharacters(in: .whitespaces)
                                    .replacingOccurrences(of: "r/", with: "")
                                guard !sub.isEmpty, !settings.briefingSubreddits.contains(sub) else { return }
                                settings.briefingSubreddits.append(sub)
                                newSubreddit = ""
                            }
                            .font(.system(size: 11))
                            .disabled(newSubreddit.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(8)
                }

                // Info
                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Morning Briefing fetches headlines from Hacker News, Reddit, and RSS feeds, then uses Claude to synthesize a ranked digest of the top 15 items.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("No API keys needed \u{2014} all sources are free public APIs.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                }
            }
            .padding(16)
        }
    }

    private func feedDisplayName(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
