import Foundation

/// Provides deterministic, render-time text masking for screenshots.
/// The database is never touched — only displayed text is replaced.
final class DemoContent {
    static let shared = DemoContent()

    enum ContentType: String {
        case client
        case project
        case task
        case note
        case session
        case email
        case emailAddress
        case gitBranch
        case filePath
        case recording
        case snippet
    }

    private var cache: [String: String] = [:]

    // MARK: - Public API

    func mask(_ text: String, as type: ContentType) -> String {
        guard !text.isEmpty else { return text }
        let key = "\(type.rawValue):\(text)"
        if let cached = cache[key] { return cached }

        let pool = pool(for: type)
        let index = Int(djb2(text) % UInt64(pool.count))
        let result = pool[index]
        cache[key] = result
        return result
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Hash

    /// djb2 hash — fast, deterministic, good distribution for short strings.
    private func djb2(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }

    // MARK: - Pools

    private func pool(for type: ContentType) -> [String] {
        switch type {
        case .client:
            return [
                "Meridian Labs", "Apex Digital", "Cobalt Systems", "Luminary AI",
                "Redwood Analytics", "Prism Software", "Vertex Cloud", "Ironclad Tech",
                "Helix Dynamics", "Quilted Data", "Starline Corp", "Nimbus Solutions",
                "Forge Interactive", "Crestview Labs", "Onyx Platforms",
            ]
        case .project:
            return [
                "dashboard-redesign", "api-gateway", "mobile-client", "auth-service",
                "analytics-pipeline", "design-system", "billing-engine", "onboarding-flow",
                "search-indexer", "notification-hub", "cms-backend", "data-warehouse",
                "inventory-sync", "payment-processor", "user-portal",
            ]
        case .task:
            return [
                "Implement dark mode toggle", "Fix pagination bug on list view",
                "Add CSV export to reports", "Migrate auth to OAuth2",
                "Update search index schema", "Refactor API error handling",
                "Add unit tests for billing module", "Build notification preferences UI",
                "Optimize image compression pipeline", "Create onboarding walkthrough",
                "Fix timezone offset in scheduler", "Add webhook retry logic",
                "Implement rate limiting middleware", "Design new settings page layout",
                "Update third-party SDK to v3", "Add real-time sync for team boards",
                "Fix memory leak in file watcher", "Build admin audit log view",
            ]
        case .note:
            return [
                "Architecture Decision: Event Sourcing", "Sprint Planning Notes — Q2",
                "API Design Review Findings", "Performance Bottleneck Analysis",
                "Database Migration Strategy", "Deployment Checklist — Production",
                "Security Audit Remediation Plan", "Tech Debt Inventory",
                "User Feedback Synthesis", "Monitoring & Alerting Setup",
                "Code Style Guidelines Update", "Feature Flag Rollout Plan",
            ]
        case .session:
            return [
                "refactor-auth-flow", "fix-dashboard-charts", "add-export-feature",
                "optimize-db-queries", "update-api-docs", "build-settings-page",
                "debug-websocket-issue", "migrate-to-swift6", "implement-caching",
                "redesign-onboarding", "fix-notification-bug", "add-search-filters",
            ]
        case .email:
            return [
                "Alex Chen", "Jordan Rivera", "Sam Patel", "Morgan Kim",
                "Casey Thompson", "Riley Jackson", "Drew Martinez", "Avery Williams",
                "Quinn Foster", "Harper Ellis", "Blake Sullivan", "Reese Cooper",
            ]
        case .emailAddress:
            return [
                "alex@meridian.io", "jordan@apex.dev", "sam@cobalt.co",
                "morgan@luminary.ai", "casey@redwood.io", "riley@prism.dev",
                "drew@vertex.cloud", "avery@ironclad.tech", "quinn@helix.io",
                "harper@quilted.co", "blake@starline.dev", "reese@nimbus.io",
            ]
        case .gitBranch:
            return [
                "feat/user-dashboard", "fix/login-redirect", "refactor/api-client",
                "feat/dark-mode", "fix/memory-leak", "feat/export-csv",
                "chore/deps-update", "feat/notifications", "fix/timezone-bug",
                "feat/search-v2", "refactor/auth-module", "feat/settings-page",
            ]
        case .filePath:
            return [
                "src/components/Dashboard.tsx", "lib/api/client.ts",
                "services/auth/handler.go", "app/models/user.rb",
                "pkg/billing/invoice.go", "src/utils/format.ts",
                "tests/integration/api_test.py", "src/hooks/useAuth.ts",
                "config/database.yml", "src/pages/Settings.vue",
                "internal/cache/redis.go", "src/middleware/rateLimit.ts",
            ]
        case .recording:
            return [
                "Sprint Planning Call", "Architecture Review", "Client Sync — Meridian",
                "Bug Triage Session", "Feature Walkthrough", "Design Critique",
                "Standup Notes", "Retrospective Discussion", "Technical Interview",
                "Onboarding Walkthrough", "Product Demo Prep", "Team Check-in",
            ]
        case .snippet:
            return [
                "Hey, just wanted to follow up on the API changes we discussed last week...",
                "The deployment went smoothly. All metrics are looking good so far...",
                "Can you review the PR when you get a chance? It's the auth refactor...",
                "We need to sync on the timeline for the Q2 launch. When works for you?",
                "Found the root cause of the performance issue — it was the N+1 query...",
                "The client approved the new design. Let's move forward with implementation...",
                "Quick heads up: the staging environment will be down for maintenance tonight...",
                "Great progress on the dashboard. A few UI tweaks needed before launch...",
            ]
        }
    }
}
