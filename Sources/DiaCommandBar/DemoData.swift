import Foundation

/// スクリーンショット用のダミーデータ。`DCB_DEMO=1` で起動すると、Dia の実際のタブ・履歴の代わりにこれを使う。
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["DCB_DEMO"] == "1" }

    static func context() -> SuggestionContext {
        let tabs: [DiaTab] = [
            tab("1", "GitHub", "https://github.com/", "Personal"),
            tab("2", "YouTube", "https://www.youtube.com/", "Personal"),
            tab("3", "Claude", "https://claude.ai/new", "Personal"),
            tab("4", "Swift.org - Documentation", "https://www.swift.org/documentation/", "Personal"),
            tab("5", "Apple Developer Documentation", "https://developer.apple.com/documentation/", "Personal"),
            tab("6", "Hacker News", "https://news.ycombinator.com/", "Personal"),
            tab("7", "swiftlang/swift: The Swift Programming Language", "https://github.com/swiftlang/swift", "Work"),
            tab("8", "Figma", "https://www.figma.com/", "Work"),
            tab("9", "Notion", "https://www.notion.so/", "Work"),
        ]
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let historyURLs: [(String, String, Int)] = [
            ("https://github.com/trending", "Trending repositories on GitHub today", 40),
            ("https://github.com/explore", "Explore GitHub", 12),
            ("https://github.blog/", "The GitHub Blog", 8),
            ("https://www.swift.org/", "Swift.org", 30),
            ("https://developer.apple.com/documentation/appkit", "AppKit | Apple Developer Documentation", 25),
            ("https://www.youtube.com/", "YouTube", 50),
            ("https://claude.ai/", "Claude", 60),
        ]
        let history = historyURLs.enumerated().map { i, h in
            HistoryEntry(url: h.0, title: h.1, visitCount: h.2, typedCount: h.2 / 5,
                         lastVisit: now - Int64(i) * 3_600_000_000,
                         hay: Array((h.1 + " " + InputResolver.prettyURL(h.0)).lowercased().utf8))
        }
        var lastVisit: [String: Int64] = [:]
        for (i, t) in tabs.enumerated() { lastVisit[t.url] = now - Int64(i) * 60_000_000 }

        var ctx = SuggestionContext()
        ctx.tabs = tabs
        ctx.activeSpace = "Personal"
        ctx.activeTabID = "0"
        ctx.spaces = ["Personal", "Work"]
        ctx.history = history
        ctx.lastVisitByURL = lastVisit
        ctx.hostRank = ["github.com", "youtube.com", "claude.ai", "swift.org", "developer.apple.com", "notion.so"]
        return ctx
    }

    private static func tab(_ id: String, _ title: String, _ url: String, _ space: String) -> DiaTab {
        DiaTab(id: id, title: title, url: url, space: space)
    }
}
