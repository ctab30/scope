import SwiftUI

struct ConsoleLogPopover: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Console")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text("\(tab.consoleLogs.count) entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button("Clear") {
                    tab.clearConsoleLogs()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            if tab.consoleLogs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("No console output")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tab.consoleLogs) { entry in
                                logEntryRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: tab.consoleLogs.count) { _, _ in
                        if let last = tab.consoleLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 300)
    }

    @ViewBuilder
    private func logEntryRow(_ entry: ConsoleLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: entry.icon)
                .font(.system(size: 9))
                .foregroundColor(entry.color)
                .frame(width: 14, alignment: .center)
                .padding(.top, 3)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(entry.level == "error" ? Color.red.opacity(0.06) : Color.clear)
    }
}
