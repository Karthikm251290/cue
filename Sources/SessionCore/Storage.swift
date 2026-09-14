import CPlatform
import Foundation

public enum Paths {
  public static var root: URL {
    if let override = ProcessInfo.processInfo.environment["SESSION_CONTROL_HOME"] {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/SessionControl")
  }
  public static var spool: URL { root.appendingPathComponent("events") }
  public static func prepare() throws {
    for dir in [root, spool] {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
}
public final class Store {
  private var db: OpaquePointer?
  public init(url: URL) throws {
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else { throw failure() }
    sqlite3_busy_timeout(db, 1000)
    try exec(
      "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL); PRAGMA user_version=1;"
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  deinit { sqlite3_close(db) }
  private func failure() -> NSError {
    NSError(
      domain: "Storage", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) }
          ?? "Unable to open session database"
      ])
  }
  private func exec(_ sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() }
  }
  public func load() throws -> Board {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT json FROM state WHERE id=1", -1, &stmt, nil) == SQLITE_OK
    else { throw failure() }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return Board() }
    let size = Int(sqlite3_column_bytes(stmt, 0))
    guard let ptr = sqlite3_column_blob(stmt, 0) else { return Board() }
    return try JSONDecoder().decode(Board.self, from: Data(bytes: ptr, count: size))
  }
  public func save(_ board: Board) throws {
    let data = try JSONEncoder().encode(board)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard
      sqlite3_prepare_v2(
        db,
        "INSERT INTO state(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        -1, &stmt, nil) == SQLITE_OK
    else { throw failure() }
    try data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(data.count), nil)
      if sqlite3_step(stmt) != SQLITE_DONE { throw failure() }
    }
  }
}
public enum Spool {
  public static func write(_ event: Event) throws {
    try Paths.prepare()
    // Bounded durable ingress; no output is ever sent to the provider.
    let existing =
      (try? FileManager.default.contentsOfDirectory(
        at: Paths.spool, includingPropertiesForKeys: nil)) ?? []
    if existing.count >= 4096 {
      try? Data("Event queue exceeded 4096 entries. Some older events were dropped.".utf8).write(
        to: Paths.root.appendingPathComponent("event-overflow"), options: .atomic)
      for f in existing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(
        existing.count - 4095)
      { try? FileManager.default.removeItem(at: f) }
    }
    let file = Paths.spool.appendingPathComponent(
      String(format: "%020.0f", event.date.timeIntervalSince1970 * 1_000_000) + "-"
        + UUID().uuidString + ".json")
    try JSONEncoder().encode(event).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
