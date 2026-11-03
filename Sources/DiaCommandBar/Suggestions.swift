import Foundation

/// Tab で切り替えられる検索先（Arc / Chrome の "Tab to search" 相当）
struct SearchEngine: Equatable {
    let id: String
    let name: String
    let keywords: [String]
    let home: String
    let template: String // %s にクエリ
    let isAI: Bool

    func url(for query: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))!
    }

    var actionLabel: String { isAI ? "\(name) に聞く" : "\(name) で検索" }

    static let claude = SearchEngine(id: "claude", name: "Claude", keywords: ["claude", "クロード"],
                                     home: "https://claude.ai/", template: "https://claude.ai/new?q=%s", isAI: true)
    static let chatgpt = SearchEngine(id: "chatgpt", name: "ChatGPT", keywords: ["chatgpt", "gpt"],
                                      home: "https://chatgpt.com/", template: "https://chatgpt.com/?q=%s", isAI: true)

    static let all: [SearchEngine] = [
        claude, chatgpt,
        SearchEngine(id: "perplexity", name: "Perplexity", keywords: ["perplexity"],
                     home: "https://www.perplexity.ai/", template: "https://www.perplexity.ai/search?q=%s", isAI: true),
        SearchEngine(id: "google", name: "Google", keywords: ["google"],
                     home: "https://www.google.com/", template: "https://www.google.com/search?q=%s", isAI: false),
        SearchEngine(id: "youtube", name: "YouTube", keywords: ["youtube"],
                     home: "https://www.youtube.com/", template: "https://www.youtube.com/results?search_query=%s", isAI: false),
        SearchEngine(id: "github", name: "GitHub", keywords: ["github"],
                     home: "https://github.com/", template: "https://github.com/search?q=%s&type=repositories", isAI: false),
        SearchEngine(id: "wikipedia", name: "Wikipedia", keywords: ["wikipedia", "wiki"],
                     home: "https://ja.wikipedia.org/", template: "https://ja.wikipedia.org/w/index.php?search=%s", isAI: false),
        SearchEngine(id: "amazon", name: "Amazon", keywords: ["amazon"],
                     home: "https://www.amazon.co.jp/", template: "https://www.amazon.co.jp/s?k=%s", isAI: false),
        SearchEngine(id: "x", name: "X", keywords: ["twitter", "x.com"],
                     home: "https://x.com/", template: "https://x.com/search?q=%s", isAI: false),
    ]

    /// 入力がキーワードの先頭部分なら該当エンジン（2 文字以上）
    static func matching(_ userText: String) -> SearchEngine? {
        let t = userText.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 2, !t.contains(" ") else { return nil }
        return all.first { $0.keywords.contains { $0.hasPrefix(t) } }
    }
}

enum SuggestionAction: Equatable {
    case open(URL)
    case switchTab(DiaTab)
    case enterScope(SearchEngine)
    case focusSpace(String)
    case copyURL
    case closeTab
    case duplicateTab
}

struct Suggestion: Equatable {
    enum Kind { case typed, tab, history, searchSuggest, engine, ai, command }
    let kind: Kind
    let title: String
    let subtitle: String?
    /// favicon を引くページ URL。nil なら symbol を使う
    let faviconURL: String?
    let symbol: String
    let actionLabel: String
    let action: SuggestionAction

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.kind == b.kind && a.action == b.action }
}

/// 候補の生成。ローカルの情報（タブ・履歴）はすべて同期的に計算するので、
/// Enter 時に作り直しても入力と食い違わない。非同期なのは Google サジェストだけ。
struct SuggestionContext {
    var tabs: [DiaTab] = []
    var activeSpace = ""
    var activeTabID = ""
    var spaces: [String] = []
    var history: [HistoryEntry] = []
    var lastVisitByURL: [String: Int64] = [:]
    var hostRank: [String] = []
    var searchPhrases: (query: String, phrases: [String]) = ("", [])
}

enum Ranker {
    static let maxRows = 10
    static let maxTabs = 3
    static let maxCommands = 2
    static let maxHistory = 3
    static let maxSearch = 2
    static let maxRecent = 6

    // Arc の command_bar_behavior.json にある「タイトル + ホストで重複排除する」ホスト
    private static let dedupByTitleAndHost: Set<String> = [
        "figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us", "opentable.com",
        "zillow.com", "github.com", "app.mode.com", "console.cloud.google.com",
    ]

    /// - text: 入力欄の文字列（インライン補完を含む）
    /// - userText: ユーザーが実際に打った部分（補完を含まない）
    static func build(text raw: String, userText: String, scope: SearchEngine?, _ ctx: SuggestionContext) -> [Suggestion] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scope { return scoped(text, scope, ctx) }
        if text.isEmpty { return recentTabs(ctx) }

        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        var rows: [Suggestion] = []
        rows += matchTabs(tokens, ctx)
        rows += matchCommands(userText, ctx)
        let typed = InputResolver.typedSuggestion(for: text)
        if let typed { rows.append(typed) }

        let hint = SearchEngine.matching(userText)
        if let hint {
            rows.append(Suggestion(kind: .engine, title: hint.name, subtitle: "Tab で \(hint.actionLabel)",
                                   faviconURL: hint.home, symbol: "magnifyingglass",
                                   actionLabel: hint.actionLabel, action: .enterScope(hint)))
        }
        var seen = Set(ctx.tabs.map { dedupKey(url: $0.url, title: $0.title) })
        rows += matchHistory(tokens, ctx, seen: &seen)

        if ctx.searchPhrases.query.trimmingCharacters(in: .whitespacesAndNewlines) == userText.trimmingCharacters(in: .whitespacesAndNewlines) {
            let current = text.lowercased()
            rows += ctx.searchPhrases.phrases
                .filter { $0.lowercased() != current }
                .prefix(maxSearch)
                .map { phrase in
                    Suggestion(kind: .searchSuggest, title: phrase, subtitle: nil, faviconURL: nil,
                               symbol: "magnifyingglass", actionLabel: "Google で検索",
                               action: .open(InputResolver.searchURL(for: phrase)))
                }
        }

        // 「Claude に聞く」は優先度低めなので最後。URL を開く入力やヒントが Claude のときは出さない
        let isURLInput: Bool = {
            if case .open(let url)? = typed?.action { return url.host != "www.google.com" }
            return false
        }()
        if !isURLInput, hint != .claude {
            let claude = Suggestion(kind: .ai, title: text, subtitle: nil, faviconURL: SearchEngine.claude.home,
                                    symbol: "sparkles", actionLabel: SearchEngine.claude.actionLabel,
                                    action: .open(SearchEngine.claude.url(for: text)))
            // 上限で押し出されないよう、溢れる場合は直前の行と入れ替える
            if rows.count >= maxRows { rows = Array(rows.prefix(maxRows - 1)) }
            rows.append(claude)
        }
        return Array(rows.prefix(maxRows))
    }

    // MARK: - Sources

    private static func scoped(_ text: String, _ engine: SearchEngine, _ ctx: SuggestionContext) -> [Suggestion] {
        guard !text.isEmpty else { return [] }
        var rows = [Suggestion(kind: .typed, title: text, subtitle: nil, faviconURL: engine.home, symbol: "magnifyingglass",
                               actionLabel: engine.actionLabel, action: .open(engine.url(for: text)))]
        if !engine.isAI, ctx.searchPhrases.query == text {
            rows += ctx.searchPhrases.phrases
                .filter { $0.lowercased() != text.lowercased() }
                .prefix(5)
                .map { Suggestion(kind: .searchSuggest, title: $0, subtitle: nil, faviconURL: nil, symbol: "magnifyingglass",
                                  actionLabel: engine.actionLabel, action: .open(engine.url(for: $0))) }
        }
        return rows
    }

    private static func recentTabs(_ ctx: SuggestionContext) -> [Suggestion] {
        uniqueTabs(ctx.tabs.filter { $0.space == ctx.activeSpace })
            .filter { $0.id != ctx.activeTabID && !$0.url.isEmpty }
            .enumerated()
            .sorted { a, b in
                let ta = ctx.lastVisitByURL[a.element.url] ?? 0
                let tb = ctx.lastVisitByURL[b.element.url] ?? 0
                return ta != tb ? ta > tb : a.offset < b.offset
            }
            .prefix(maxRecent)
            .map { tabSuggestion($0.element, ctx) }
    }

    /// Dia の `tabs of profile` はお気に入り・ピン留めとウィンドウのタブを重ねて返すので、id と URL で重複を除く
    private static func uniqueTabs(_ tabs: [DiaTab]) -> [DiaTab] {
        var ids = Set<String>(), urls = Set<String>()
        return tabs.filter { ids.insert($0.space + $0.id).inserted && urls.insert($0.space + $0.url).inserted }
    }

    private static func matchTabs(_ tokens: [[UInt8]], _ ctx: SuggestionContext) -> [Suggestion] {
        guard let first = tokens.first else { return [] }
        let firstString = String(decoding: first, as: UTF8.self)
        let scored: [(DiaTab, Int)] = uniqueTabs(ctx.tabs).compactMap { tab in
            let title = tab.title.lowercased()
            let hay = Array((title + " " + InputResolver.prettyURL(tab.url).lowercased()).utf8)
            guard tokens.allSatisfy({ wordPrefixMatch($0, in: hay) }) else { return nil }
            var score = 0
            if bareHost(tab.url).hasPrefix(firstString) { score += 40 }
            if title.hasPrefix(firstString) { score += 30 }
            if tab.space == ctx.activeSpace { score += 25 }
            if tab.id == ctx.activeTabID { score -= 30 }
            return (tab, score)
        }
        // 同じ URL が複数スペースにあれば、現在のスペースのものを優先して 1 つにする
        var seenURL = Set<String>()
        return scored
            .sorted { $0.1 > $1.1 }
            .filter { seenURL.insert($0.0.url).inserted }
            .prefix(maxTabs)
            .map { tabSuggestion($0.0, ctx) }
    }

    private static func matchCommands(_ userText: String, _ ctx: SuggestionContext) -> [Suggestion] {
        let tokens = userText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // 2 文字だと "cl" で close が出るなどノイズが多いので 3 文字から
        guard let first = tokens.first, first.count >= 3 || !first.allSatisfy(\.isASCII) else { return [] }
        typealias Command = (title: String, keywords: [String], symbol: String, action: SuggestionAction)
        var commands: [Command] = ctx.spaces.filter { $0 != ctx.activeSpace }.map {
            ("「\($0)」に移動", [$0.lowercased(), "space", "workspace", "スペース", "ワークスペース"], "rectangle.stack", .focusSpace($0))
        }
        commands += [
            ("URL をコピー", ["copy", "url", "コピー"], "link", .copyURL),
            ("タブを閉じる", ["close", "tab", "閉じる", "タブ"], "xmark", .closeTab),
            ("タブを複製", ["duplicate", "tab", "複製", "タブ"], "plus.square.on.square", .duplicateTab),
        ]
        return commands
            .filter { c in tokens.allSatisfy { t in c.keywords.contains { $0.hasPrefix(t) } } }
            .prefix(maxCommands)
            .map { Suggestion(kind: .command, title: $0.title, subtitle: nil, faviconURL: nil, symbol: $0.symbol,
                              actionLabel: "実行", action: $0.action) }
    }

    private static func matchHistory(_ tokens: [[UInt8]], _ ctx: SuggestionContext, seen: inout Set<String>) -> [Suggestion] {
        guard let first = tokens.first else { return [] }
        let firstString = String(decoding: first, as: UTF8.self)
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        var scored: [(HistoryEntry, Double)] = []
        for e in ctx.history {
            guard tokens.allSatisfy({ wordPrefixMatch($0, in: e.hay) }) else { continue }
            let days = Double(now - e.lastVisit) / 86_400_000_000
            var score = log2(Double(e.visitCount) + 1) * 8 + Double(min(e.typedCount, 10)) * 6
            score += days < 1 ? 25 : days < 7 ? 15 : days < 30 ? 8 : 0
            if bareHost(e.url).hasPrefix(firstString) { score += 40 }
            if e.title.lowercased().hasPrefix(firstString) { score += 15 }
            scored.append((e, score))
        }
        scored.sort { $0.1 > $1.1 }
        var out: [Suggestion] = []
        for (e, _) in scored where out.count < maxHistory {
            guard let url = URL(string: e.url), seen.insert(dedupKey(url: e.url, title: e.title)).inserted else { continue }
            out.append(Suggestion(kind: .history, title: e.title.isEmpty ? InputResolver.prettyURL(e.url) : e.title,
                                  subtitle: InputResolver.prettyURL(e.url), faviconURL: e.url, symbol: "clock",
                                  actionLabel: "開く", action: .open(url)))
        }
        return out
    }

    private static func tabSuggestion(_ tab: DiaTab, _ ctx: SuggestionContext) -> Suggestion {
        Suggestion(kind: .tab, title: tab.title.isEmpty ? InputResolver.prettyURL(tab.url) : tab.title,
                   subtitle: InputResolver.prettyURL(tab.url), faviconURL: tab.url, symbol: "square.on.square",
                   actionLabel: tab.space == ctx.activeSpace ? "タブに切り替え" : tab.space,
                   action: .switchTab(tab))
    }

    // MARK: - Inline completion

    /// "gi" → "thub.com" のように、打った文字列に続くホスト名を返す
    static func inlineCompletion(for userText: String, _ ctx: SuggestionContext) -> String? {
        guard userText.count >= 2, userText.allSatisfy({ $0.isASCII && !$0.isWhitespace }), !userText.contains("/") else { return nil }
        let lower = userText.lowercased()
        guard let host = ctx.hostRank.first(where: { $0.hasPrefix(lower) && $0.count > lower.count }) else { return nil }
        return String(host.dropFirst(lower.count))
    }

    // MARK: - Helpers

    /// ASCII のトークンは単語の先頭一致（"hub" で github にはヒットしない）。日本語などは部分一致。
    /// 1 打鍵ごとに数千件を走査するので、UTF-8 バイト列に memmem をかける。
    static func wordPrefixMatch(_ token: [UInt8], in hay: [UInt8]) -> Bool {
        guard !token.isEmpty, token.count <= hay.count else { return false }
        let asciiToken = token.allSatisfy { $0 < 0x80 }
        return hay.withUnsafeBytes { h in
            token.withUnsafeBytes { t in
                guard let base = h.baseAddress, let tBase = t.baseAddress else { return false }
                var offset = 0
                while offset <= h.count - t.count {
                    guard let found = memmem(base + offset, h.count - offset, tBase, t.count) else { return false }
                    let index = base.distance(to: UnsafeRawPointer(found))
                    if !asciiToken || index == 0 { return true }
                    let prev = h[index - 1]
                    let isAlnum = (prev >= 0x30 && prev <= 0x39) || (prev >= 0x61 && prev <= 0x7A) || (prev >= 0x41 && prev <= 0x5A)
                    if !isAlnum { return true } // 記号・空白・非 ASCII の直後は単語の先頭とみなす
                    offset = index + 1
                }
                return false
            }
        }
    }

    static func bareHost(_ url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func dedupKey(url: String, title: String) -> String {
        let host = bareHost(url)
        if dedupByTitleAndHost.contains(host) { return host + "|" + title }
        var key = InputResolver.prettyURL(url)
        if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
}

enum InputResolver {
    static func searchURL(for query: String) -> URL {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!
    }

    /// 入力が URL（またはドメイン）っぽければ URL を返す。
    static func directURL(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        if let r = text.range(of: "://"), text.distance(from: text.startIndex, to: r.lowerBound) > 0 {
            return URL(string: text)
        }
        if text.hasPrefix("about:") { return URL(string: text) }

        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let looksLikeHost =
            host == "localhost"
            || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            || host.range(of: #"^([a-z0-9-]+\.)+[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard looksLikeHost else { return nil }
        let scheme = (host == "localhost" || host.first?.isNumber == true) ? "http" : "https"
        return URL(string: "\(scheme)://\(text)")
    }

    /// 入力そのものに対するアクション。現在の入力から同期的に作るので古くならない。
    static func typedSuggestion(for raw: String) -> Suggestion? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = directURL(from: text) {
            return Suggestion(kind: .typed, title: text, subtitle: nil, faviconURL: url.absoluteString,
                              symbol: "globe", actionLabel: "開く", action: .open(url))
        }
        return Suggestion(kind: .typed, title: text, subtitle: nil, faviconURL: nil,
                          symbol: "magnifyingglass", actionLabel: "Google で検索", action: .open(searchURL(for: text)))
    }

    static func prettyURL(_ s: String) -> String {
        var t = s
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        return t
    }
}

/// Google のサジェスト API。デバウンスはせず、入力ごとに前のリクエストをキャンセルして即投げる。
/// 古い応答は呼び出し側で「今の入力と一致するか」を見て捨てる。
final class SearchSuggestClient {
    private var task: URLSessionDataTask?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    func fetch(_ query: String, completion: @escaping (String, [String]) -> Void) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        c.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "hl", value: Locale.preferredLanguages.first ?? "ja"),
            URLQueryItem(name: "q", value: q),
        ]
        guard let url = c.url else { return }
        let t = session.dataTask(with: url) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2, let list = json[1] as? [String]
            else { return }
            DispatchQueue.main.async { completion(query, list) }
        }
        task = t
        t.resume()
    }

    func cancel() { task?.cancel() }
}
