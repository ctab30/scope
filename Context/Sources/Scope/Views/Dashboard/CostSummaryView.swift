import SwiftUI
import GRDB

/// Aggregated cost data for display.
struct CostData {
    var totalCost: Double = 0
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCacheCreationTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var sessionCount: Int = 0
    var costByModel: [(model: String, cost: Double)] = []
    var recentDailyCosts: [(date: String, cost: Double)] = []
}

/// Shows project-level cost summary with total spend, model breakdown,
/// and a 7-day cost bar chart.
struct CostSummaryView: View {
    @EnvironmentObject var appState: AppState
    @State private var costData = CostData()
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Label("Cost Tracker", systemImage: "dollarsign.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                // Total cost badge
                Text(String(format: "$%.2f", costData.totalCost))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(costColor(costData.totalCost))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(costColor(costData.totalCost).opacity(0.1))
                    )

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                // Stats row
                HStack(spacing: 8) {
                    CostStatCard(
                        title: "Sessions",
                        value: "\(costData.sessionCount)",
                        icon: "clock",
                        color: .blue
                    )
                    CostStatCard(
                        title: "Avg/Session",
                        value: costData.sessionCount > 0
                            ? String(format: "$%.2f", costData.totalCost / Double(costData.sessionCount))
                            : "$0.00",
                        icon: "chart.bar",
                        color: .purple
                    )
                    CostStatCard(
                        title: "Tokens",
                        value: formatTokenCount(costData.totalInputTokens + costData.totalOutputTokens),
                        icon: "text.word.spacing",
                        color: .teal
                    )
                }

                // Model breakdown
                if !costData.costByModel.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By Model")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

                        let maxCost = costData.costByModel.first?.cost ?? 1
                        ForEach(costData.costByModel, id: \.model) { entry in
                            ModelCostBar(
                                model: shortModelName(entry.model),
                                cost: entry.cost,
                                ratio: maxCost > 0 ? entry.cost / maxCost : 0
                            )
                        }
                    }
                }

                // Daily cost chart (last 7 days)
                if !costData.recentDailyCosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last 7 Days")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

                        DailyCostChart(days: costData.recentDailyCosts)
                            .frame(height: 60)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
        .onAppear { loadCostData() }
        .onChange(of: appState.currentProject) { _, _ in loadCostData() }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsDidChange)) { _ in
            loadCostData()
        }
    }

    // MARK: - Data Loading

    private func loadCostData() {
        guard let project = appState.currentProject else {
            costData = CostData()
            return
        }

        do {
            costData = try DatabaseService.shared.dbQueue.read { db -> CostData in
                var data = CostData()

                // Fetch all sessions for this project
                let sessions = try Session
                    .filter(Session.Columns.projectId == project.id)
                    .fetchAll(db)

                data.sessionCount = sessions.count

                // Aggregate totals
                var modelCosts: [String: Double] = [:]
                var dailyCosts: [String: Double] = [:]
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "MM/dd"

                for session in sessions {
                    data.totalInputTokens += session.inputTokens
                    data.totalOutputTokens += session.outputTokens
                    data.totalCacheCreationTokens += session.cacheCreationTokens
                    data.totalCacheReadTokens += session.cacheReadTokens

                    let cost = session.estimatedCost
                    data.totalCost += cost

                    // By model
                    let model = session.model ?? "unknown"
                    modelCosts[model, default: 0] += cost

                    // By day
                    if let date = session.startedAt {
                        let dayKey = dayFormatter.string(from: date)
                        dailyCosts[dayKey, default: 0] += cost
                    }
                }

                // Sort model costs descending
                data.costByModel = modelCosts
                    .map { (model: $0.key, cost: $0.value) }
                    .sorted { $0.cost > $1.cost }

                // Build last 7 days (fill in zero-cost days)
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                var days: [(date: String, cost: Double)] = []
                for i in (0..<7).reversed() {
                    if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                        let key = dayFormatter.string(from: date)
                        days.append((date: key, cost: dailyCosts[key] ?? 0))
                    }
                }
                data.recentDailyCosts = days

                return data
            }
        } catch {
            print("CostSummaryView: failed to load cost data: \(error)")
        }
    }

    // MARK: - Helpers

    private func costColor(_ cost: Double) -> Color {
        if cost > 10 { return .red }
        if cost > 5 { return .orange }
        return .green
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus")   { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku")  { return "Haiku" }
        return model
    }
}

// MARK: - Cost Stat Card

struct CostStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color.opacity(0.7))

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Model Cost Bar

struct ModelCostBar: View {
    let model: String
    let cost: Double
    let ratio: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(model)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(modelColor.opacity(0.5))
                    .frame(width: max(4, geo.size.width * ratio))
            }
            .frame(height: 10)

            Text(String(format: "$%.2f", cost))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.primary.opacity(0.7))
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 16)
    }

    private var modelColor: Color {
        switch model {
        case "Opus": return .red
        case "Sonnet": return .blue
        case "Haiku": return .green
        default: return .gray
        }
    }
}

// MARK: - Daily Cost Chart

struct DailyCostChart: View {
    let days: [(date: String, cost: Double)]

    private var maxCost: Double {
        max(days.map(\.cost).max() ?? 0, 0.01) // avoid division by zero
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 3) {
                    // Bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(day.cost))
                        .frame(height: max(2, 44 * (day.cost / maxCost)))

                    // Date label
                    Text(day.date)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barColor(_ cost: Double) -> Color {
        if cost == 0 { return Color(nsColor: .separatorColor).opacity(0.3) }
        if cost > 5 { return .orange.opacity(0.7) }
        return .green.opacity(0.6)
    }
}
