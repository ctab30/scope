import SwiftUI
import AppKit

struct BriefingDrawerView: View {
    @EnvironmentObject var briefingService: BriefingService
    @EnvironmentObject var appSettings: AppSettings
    @Binding var showDrawer: Bool
    @State private var pastDigests: [BriefingDigest] = []
    @State private var showPastBriefings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if briefingService.isGenerating {
                generatingView
            } else if briefingService.latestItems.isEmpty {
                emptyView
            } else {
                itemsList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                Text("Morning Briefing")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task {
                        await briefingService.generateNow(settings: appSettings)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(briefingService.isGenerating)
                .help("Refresh briefing")

                Button {
                    showDrawer = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let digest = briefingService.latestDigest {
                Text("\(relativeTime(digest.generatedAt))  \u{2022}  \(digest.itemCount) items")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Generating State

    private var generatingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Generating briefing...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Fetching news and synthesizing with Claude")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No briefing yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Button("Generate First Briefing") {
                Task {
                    await briefingService.generateNow(settings: appSettings)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let grouped = Dictionary(grouping: briefingService.latestItems, by: \.category)
                let sortedCategories = grouped.keys.sorted { a, b in
                    let aMax = grouped[a]?.map(\.relevanceScore).max() ?? 0
                    let bMax = grouped[b]?.map(\.relevanceScore).max() ?? 0
                    return aMax > bMax
                }

                ForEach(sortedCategories, id: \.self) { category in
                    if let items = grouped[category] {
                        categorySection(category: category, items: items)
                    }
                }

                pastBriefingsSection
            }
            .padding(16)
        }
    }

    // MARK: - Category Section

    private func categorySection(category: String, items: [BriefingItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(category.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(1)
                Text("(\(items.count))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            ForEach(items) { item in
                itemCard(item)
            }
        }
    }

    // MARK: - Item Card

    private func itemCard(_ item: BriefingItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(item.isRead ? .secondary : .primary)
                .lineLimit(2)

            Text(item.summary)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(item.sourceName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(sourceColor(for: item.sourceName))
                    )

                Spacer()

                Button {
                    if let url = URL(string: item.sourceUrl) {
                        NSWorkspace.shared.open(url)
                    }
                    if let id = item.id {
                        briefingService.markAsRead(itemId: id)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Open")
                            .font(.system(size: 10))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                Button {
                    if let id = item.id {
                        briefingService.toggleSaved(itemId: id)
                    }
                } label: {
                    Image(systemName: item.isSaved ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(item.isSaved ? .yellow : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(item.isSaved ? "Unsave" : "Save")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(item.isRead ? 0.02 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onTapGesture {
            if let id = item.id, !item.isRead {
                briefingService.markAsRead(itemId: id)
            }
        }
    }

    // MARK: - Past Briefings

    private var pastBriefingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !showPastBriefings {
                    pastDigests = briefingService.loadPastDigests()
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPastBriefings.toggle()
                }
            } label: {
                HStack {
                    Text("Past Briefings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Image(systemName: showPastBriefings ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showPastBriefings {
                ForEach(pastDigests.dropFirst()) { digest in
                    HStack {
                        Text(digest.generatedAt.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("\u{2022}")
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("\(digest.itemCount) items")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let id = digest.id {
                            briefingService.latestDigest = digest
                            briefingService.latestItems.removeAll()
                            let items = briefingService.loadItems(forDigest: id)
                            briefingService.latestItems = items
                            briefingService.unreadCount = items.filter { !$0.isRead }.count
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func sourceColor(for name: String) -> Color {
        switch name {
        case "Hacker News": return .orange
        case _ where name.hasPrefix("r/"): return .blue
        default: return .purple
        }
    }
}
