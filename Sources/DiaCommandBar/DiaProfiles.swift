import AppKit

/// Dia の Chromium プロファイル（User Data/Profile N）とウィンドウ位置。
enum DiaProfiles {
    static let userDataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dia/User Data")

    /// Local State の info_cache から (ディレクトリ, 表示名) の一覧を返す
    static func all() -> [(dir: URL, name: String)] {
        let localState = userDataDir.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        return cache
            .map { (userDataDir.appendingPathComponent($0.key), ($0.value["name"] as? String) ?? $0.key) }
            .sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    /// Dia の最前面ウィンドウの枠（Cocoa 座標）。画面収録・アクセシビリティ権限は不要。
    static func frontWindowFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: DiaBridge.bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // リストは前面→背面の順
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 300, bounds.height > 200
            else { continue }
            // CG はメイン画面左上原点、Cocoa は左下原点
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }
}
