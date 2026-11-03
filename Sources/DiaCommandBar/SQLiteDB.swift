import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Dia が使用中の DB を読むための最小ラッパー。
/// immutable=1 で開くのでロックを取らず、Dia 側の書き込みを妨げない（多少古い内容が見えることはある）。
final class SQLiteDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        let uri = "file:\(encoded)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    struct Row {
        fileprivate let stmt: OpaquePointer
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    func query(_ sql: String, _ args: [String] = [], each: (Row) -> Bool = { _ in true }) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), a, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if !each(Row(stmt: stmt)) { break }
        }
    }
}
