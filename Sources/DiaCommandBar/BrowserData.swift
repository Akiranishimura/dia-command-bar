import AppKit

struct HistoryEntry {
    let url: String
    let title: String
    let visitCount: Int
    let typedCount: Int
    let lastVisit: Int64 // Chromium 時刻（1601-01-01 からのマイクロ秒）
    let hay: [UInt8]     // 検索用（小文字のタイトル + URL の UTF-8）
}

struct ProfileHistory {
    let dir: URL
    let name: String
    let entries: [HistoryEntry]
    let lastVisitByURL: [String: Int64]
    /// インライン補完用。よく行くホスト順（www. なし）
    let hostRank: [String]
}

/// 全 Chromium プロファイルの履歴と favicon。読み込みはバックグラウンド、検索はメモリ上で同期的に行う。
final class BrowserData {
    private let queue = DispatchQueue(label: "BrowserData", qos: .userInitiated)
    private(set) var profiles: [ProfileHistory] = []
    private var loadedAt = Date.distantPast
    private var loading = false
    private var spaceToProfile: [String: URL] = [:]

    // queue 上でのみ触る
    private var faviconDBs: [SQLiteDB] = []
    private var faviconDBsOpened = false

    private let faviconCache = NSCache<NSString, NSImage>()
    private var faviconMisses = Set<String>()
    private var pendingFavicons = Set<String>()
    private let faviconSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    init() {
        // favicon は起動直後から引けるように先に開いておく
        queue.async { self.reopenFaviconDBs() }
    }

    /// 古くなっていたら全プロファイルの履歴を読み直す。completion はメインスレッド。
    func refreshIfNeeded(completion: @escaping () -> Void) {
        guard !loading, Date().timeIntervalSince(loadedAt) > 60 else { return }
        loading = true
        queue.async {
            self.reopenFaviconDBs()
            let loaded = DiaProfiles.all().map { Self.loadHistory(dir: $0.dir, name: $0.name) }
            DispatchQueue.main.async {
                self.profiles = loaded
                self.loadedAt = Date()
                self.loading = false
                self.spaceToProfile = [:]
                completion()
            }
        }
    }

    /// Dia のスペースに対応する Chromium プロファイルの履歴。
    /// スペースとプロファイルの対応はどこにも保存されていないので、
    /// 名前が一致すればそれ、しなければ「そのスペースで開いているタブの URL を最も多く履歴に持つプロファイル」を使う。
    func history(forSpace space: String, tabURLs: [String]) -> ProfileHistory? {
        guard !profiles.isEmpty else { return nil }
        if let dir = spaceToProfile[space], let p = profiles.first(where: { $0.dir == dir }) { return p }
        let chosen = profiles.first { $0.name.caseInsensitiveCompare(space) == .orderedSame }
            ?? profiles.max { a, b in
                tabURLs.filter { a.lastVisitByURL[$0] != nil }.count < tabURLs.filter { b.lastVisitByURL[$0] != nil }.count
            }
        if let chosen, !tabURLs.isEmpty { spaceToProfile[space] = chosen.dir }
        return chosen
    }

    private static func loadHistory(dir: URL, name: String) -> ProfileHistory {
        var entries: [HistoryEntry] = []
        var byURL: [String: Int64] = [:]
        var hostScore: [String: Int] = [:]
        if let db = SQLiteDB(path: dir.appendingPathComponent("History").path) {
            let base = """
                SELECT url, title, visit_count, typed_count, last_visit_time FROM urls
                WHERE hidden = 0 AND url NOT LIKE 'https://www.google.com/search%' AND url NOT LIKE 'chrome%'
                """
            // 最近のもの + よく行くもの
            for sql in [base + " ORDER BY last_visit_time DESC LIMIT 6000",
                        base + " ORDER BY visit_count DESC LIMIT 1500"] {
                db.query(sql) { r in
                    let url = r.text(0)
                    guard byURL[url] == nil else { return true }
                    let title = r.text(1)
                    let e = HistoryEntry(url: url, title: title, visitCount: Int(r.int(2)), typedCount: Int(r.int(3)),
                                         lastVisit: r.int(4),
                                         hay: Array((title + " " + InputResolver.prettyURL(url)).lowercased().utf8))
                    entries.append(e)
                    byURL[url] = e.lastVisit
                    let host = Ranker.bareHost(url)
                    if !host.isEmpty { hostScore[host, default: 0] += e.visitCount + e.typedCount * 10 }
                    return true
                }
            }
        }
        let hostRank = hostScore.sorted { $0.value > $1.value }.prefix(3000).map(\.key)
        return ProfileHistory(dir: dir, name: name, entries: entries, lastVisitByURL: byURL, hostRank: hostRank)
    }

    // MARK: - Favicon

    /// queue 上で呼ぶ
    private func reopenFaviconDBs() {
        faviconDBs = DiaProfiles.all().compactMap { SQLiteDB(path: $0.dir.appendingPathComponent("Favicons").path) }
        faviconDBsOpened = true
    }

    func cachedFavicon(for pageURL: String) -> NSImage? {
        faviconCache.object(forKey: Self.faviconKey(pageURL) as NSString)
    }

    /// 見つかったら completion（メインスレッド）を呼ぶ。
    /// Dia の Favicons DB（全プロファイル）→ サイトの /favicon.ico の順に探す。
    func loadFavicon(for pageURL: String, completion: @escaping () -> Void) {
        let key = Self.faviconKey(pageURL)
        guard cachedFavicon(for: pageURL) == nil, !faviconMisses.contains(key), pendingFavicons.insert(key).inserted else { return }
        queue.async {
            let image = self.lookupFavicon(pageURL)
            DispatchQueue.main.async {
                if let image {
                    self.store(image, key: key, completion: completion)
                } else {
                    self.fetchFaviconFromSite(pageURL, key: key, completion: completion)
                }
            }
        }
    }

    private func store(_ image: NSImage, key: String, completion: () -> Void) {
        pendingFavicons.remove(key)
        image.size = NSSize(width: 16, height: 16)
        faviconCache.setObject(image, forKey: key as NSString)
        completion()
    }

    private func fetchFaviconFromSite(_ pageURL: String, key: String, completion: @escaping () -> Void) {
        guard let host = URL(string: pageURL)?.host, let url = URL(string: "https://\(host)/favicon.ico") else {
            pendingFavicons.remove(key)
            faviconMisses.insert(key)
            return
        }
        faviconSession.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let image = ok ? data.flatMap(NSImage.init(data:)) : nil
            DispatchQueue.main.async {
                if let image, image.isValid {
                    self.store(image, key: key, completion: completion)
                } else {
                    self.pendingFavicons.remove(key)
                    self.faviconMisses.insert(key)
                }
            }
        }.resume()
    }

    private static func faviconKey(_ pageURL: String) -> String {
        URL(string: pageURL)?.host ?? pageURL
    }

    /// queue 上で呼ぶ
    private func lookupFavicon(_ pageURL: String) -> NSImage? {
        if !faviconDBsOpened { reopenFaviconDBs() }
        // ページ URL が完全一致するアイコン
        let exact = "SELECT icon_id FROM icon_mapping WHERE page_url = ? LIMIT 1"
        // 同じホストで最も多くのページに使われているアイコン（インデックスが効く範囲検索）。
        // 「最初に見つかったもの」だと Google Doodle や Claude のアーティファクトなど別物を拾うため。
        let byHost = """
            SELECT icon_id FROM icon_mapping WHERE page_url >= ? AND page_url < ?
            GROUP BY icon_id ORDER BY COUNT(*) DESC LIMIT 1
            """
        let bitmap = """
            SELECT image_data FROM favicon_bitmaps WHERE icon_id = ? AND image_data IS NOT NULL
            ORDER BY (width >= 32) DESC, width ASC LIMIT 1
            """
        let host = URL(string: pageURL)?.host ?? ""
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        for db in faviconDBs {
            var iconID: Int64?
            db.query(exact, [pageURL]) { r in iconID = r.int(0); return false }
            if iconID == nil, !host.isEmpty {
                outer: for scheme in ["https://", "http://"] {
                    for h in [host, bare, "www." + bare] {
                        db.query(byHost, [scheme + h + "/", scheme + h + "0"]) { r in iconID = r.int(0); return false }
                        if iconID != nil { break outer }
                    }
                }
            }
            guard let iconID else { continue }
            var data: Data?
            db.query(bitmap, [String(iconID)]) { r in data = r.blob(0); return false }
            if let data, let image = NSImage(data: data) { return image }
        }
        return nil
    }
}
