import Foundation
import Combine

class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?

    private var cancellables = Set<AnyCancellable>()

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabId }
    }

    func newTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabId = tab.id

        // Forward tab property changes to trigger view updates
        tab.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            activeTabId = tabs.last?.id
        }
    }

    /// Find a tab by its UUID string.
    func tab(byId idString: String) -> BrowserTab? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return tabs.first { $0.id == uuid }
    }

    /// Open a new tab and optionally navigate to a URL. Returns the new tab.
    @discardableResult
    func openTab(url: String? = nil) -> BrowserTab {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabId = tab.id

        // Forward tab property changes
        tab.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if let url = url, !url.isEmpty {
            tab.navigate(to: url)
        }
        return tab
    }

    /// Switch active tab by UUID string. Returns true if found.
    @discardableResult
    func switchTab(to idString: String) -> Bool {
        guard let uuid = UUID(uuidString: idString) else { return false }
        guard tabs.contains(where: { $0.id == uuid }) else { return false }
        activeTabId = uuid
        return true
    }

    /// Close tab by UUID string. Returns true if found and closed.
    @discardableResult
    func closeTabById(_ idString: String) -> Bool {
        guard let uuid = UUID(uuidString: idString) else { return false }
        guard tabs.contains(where: { $0.id == uuid }) else { return false }
        closeTab(uuid)
        return true
    }

    /// Serialize all tabs to a JSON-compatible array.
    func tabsInfo() -> [[String: Any]] {
        tabs.map { tab in
            [
                "id": tab.id.uuidString,
                "title": tab.title,
                "url": tab.currentURL,
                "isActive": tab.id == activeTabId,
                "isLoading": tab.isLoading
            ] as [String: Any]
        }
    }
}
