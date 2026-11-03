import AppKit

struct DiaTab: Equatable {
    let id: String
    let title: String
    let url: String
    /// Dia のスペース名（AppleScript の profile name）
    let space: String
}

struct DiaState {
    let activeSpace: String
    let activeTabID: String
    let spaces: [String]
    let tabs: [DiaTab]
}

/// Dia の AppleScript 辞書（Dia.app/Contents/Resources/Dia.sdef）経由の操作。
/// 注意: AppleScript の "profile" は Dia の「スペース」で、Chromium のプロファイルとは 1 対 1 ではない。
enum DiaBridge {
    static let bundleID = "company.thebrowser.dia"

    // MARK: - 読み取り（バックグラウンドで osascript を叩く。UI をブロックしない）

    private static let fetchStateScript = """
    set fs to character id 31
    set rs to character id 30
    tell application id "\(bundleID)"
        if (count of windows) = 0 then return ""
        set w to front window
        set aname to name of active profile of w
        set aid to ""
        try
            set aid to id of active tab of w
        end try
        set out to {aname & fs & aid}
        repeat with p in profiles of w
            set nm to name of p
            set ids to id of tabs of p
            set ts to title of tabs of p
            set us to URL of tabs of p
            set end of out to "#" & nm
            repeat with i from 1 to count of ids
                set end of out to (item i of ids) & fs & (item i of ts) & fs & (item i of us)
            end repeat
        end repeat
    end tell
    set AppleScript's text item delimiters to rs
    return out as text
    """

    private static let queue = DispatchQueue(label: "DiaBridge.fetch", qos: .userInitiated)

    /// 全スペースのタブと、現在のスペース・タブを取得する。completion はメインスレッドで呼ばれる。
    static func fetchState(completion: @escaping (DiaState?) -> Void) {
        queue.async {
            let output = (runOsascript(fetchStateScript) ?? "").trimmingCharacters(in: .newlines)
            var records = output.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init)
            guard !records.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let header = records.removeFirst().split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard let activeSpace = header.first, !activeSpace.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var spaces: [String] = []
            var tabs: [DiaTab] = []
            var current = ""
            for r in records {
                if r.hasPrefix("#") {
                    current = String(r.dropFirst())
                    spaces.append(current)
                    continue
                }
                let f = r.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 3 else { continue }
                tabs.append(DiaTab(id: f[0], title: f[1], url: f[2], space: current))
            }
            let state = DiaState(activeSpace: activeSpace, activeTabID: header.count > 1 ? header[1] : "",
                                 spaces: spaces, tabs: tabs)
            DispatchQueue.main.async { completion(state) }
        }
    }

    private static func runOsascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 操作（パネルを閉じた後にメインスレッドで実行）

    static func openInNewTab(_ url: URL) {
        let ok = run("""
            make new tab at end of tabs of front window with properties {URL:"\(escape(url.absoluteString))"}
            """) != nil
        if !ok, let diaURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // ウィンドウが無い等で失敗したら LaunchServices で Dia に渡す
            NSWorkspace.shared.open([url], withApplicationAt: diaURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 別スペースのタブなら、スペースごと切り替わる
    static func focusTab(_ tab: DiaTab) {
        run("""
            focus (first tab of (first profile of front window whose name is "\(escape(tab.space))") whose id is "\(escape(tab.id))")
            """)
    }

    static func focusSpace(_ name: String) {
        run("focus (first profile of front window whose name is \"\(escape(name))\")")
    }

    static func activeTabURL() -> String? {
        run("return URL of active tab of front window")
    }

    static func closeActiveTab() {
        run("close active tab of front window")
    }

    static func duplicateActiveTab() {
        run("""
            set u to URL of active tab of front window
            make new tab at end of tabs of front window with properties {URL:u}
            """)
    }

    /// tell ブロックの中身を実行し、結果を文字列で返す（失敗時は nil）
    @discardableResult
    private static func run(_ body: String) -> String? {
        let source = "tell application id \"\(bundleID)\"\n\(body)\nend tell"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("[DiaCommandBar] AppleScript error: \(error)")
            return nil
        }
        return result?.stringValue ?? ""
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
