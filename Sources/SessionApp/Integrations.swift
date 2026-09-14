import AppKit
import CPlatform
import SessionCore

struct IntegrationError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}
enum ClaudeSetup {
  static let events = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest",
    "Notification", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Elicitation",
    "ElicitationResult",
  ]
  static var settings: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }
  static var reporter: URL { Paths.root.appendingPathComponent("bin/SessionReporter") }
  static var command: String {
    "'" + reporter.path.replacingOccurrences(of: "'", with: "'\\''") + "' --session-control"
  }
  static func installed(provider: Provider = .claude) -> Bool {
    let settings =
      provider == .claude
      ? Self.settings
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    let command = Self.command + (provider == .codex ? " --codex" : "")
    let events =
      provider == .claude
      ? Self.events
      : [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Interrupt",
      ]
    guard let data = try? Data(contentsOf: settings),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let hooks = json["hooks"] as? [String: Any]
    else { return false }
    return events.allSatisfy { name in
      ((hooks[name] as? [[String: Any]]) ?? []).contains { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).contains {
          ($0["command"] as? String) == command
        }
      }
    }
  }
  static func configure(install: Bool, provider: Provider = .claude) throws {
    let settings =
      provider == .claude
      ? Self.settings
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    let command = Self.command + (provider == .codex ? " --codex" : "")
    let events =
      provider == .claude
      ? Self.events
      : [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Interrupt",
      ]
    try Paths.prepare()
    if install {
      let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SessionReporter")
      guard FileManager.default.fileExists(atPath: bundled.path) else {
        throw IntegrationError(
          message: "Open the packaged application to install monitoring.")
      }
      try FileManager.default.createDirectory(
        at: reporter.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let data = try Data(contentsOf: bundled)
      try data.write(to: reporter, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reporter.path)
    }
    var json: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: settings.path) {
      let data = try Data(contentsOf: settings)
      guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw IntegrationError(
          message: "Provider settings are not a JSON object. No settings were changed.")
      }
      json = parsed
      let backup = Paths.root.appendingPathComponent(
        "\(provider.rawValue)-settings-\(UUID().uuidString).json")
      try data.write(to: backup, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    json = try HookConfiguration.merge(json, events: events, command: command, install: install)
    try FileManager.default.createDirectory(
      at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(
      to: settings, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
  }
}
@MainActor enum Navigator {
  private static let queue = DispatchQueue(
    label: "SessionControl.TerminalNavigation", qos: .userInitiated)
  static func open(_ session: Session) async throws -> Bool {
    if session.provider == .codex {
      guard UUID(uuidString: session.providerID) != nil,
        let url = URL(string: "codex://threads/\(session.providerID)")
      else { throw IntegrationError(message: "This Codex session has no valid conversation link.") }
      let application = URL(fileURLWithPath: "/Applications/Codex.app")
      guard FileManager.default.fileExists(atPath: application.path) else {
        throw IntegrationError(message: "Codex.app was not found in Applications.")
      }
      // Target the Codex application explicitly to avoid ambiguity with shared URL handlers.
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.open(
          [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
      // OS acceptance does not prove that the destination became visible.
      return false
    }
    guard let terminal = session.terminal, terminal.isLive,
      terminal.tty.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil
    else {
      throw IntegrationError(
        message:
          "The original Terminal session is no longer verified. Submit a prompt in that session to reconnect it."
      )
    }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        let tty: String
        do {
          tty =
            try terminal.tmuxPane == nil ? terminal.tty : TmuxNavigation.terminalTTY(for: terminal)
        } catch {
          continuation.resume(throwing: error)
          return
        }
        let source = """
          with timeout of 5 seconds
          tell application "Terminal"
              repeat with w in windows
                  repeat with t in tabs of w
                      if tty of t is "\(tty)" then
                          set selected tab of w to t
                          set miniaturized of w to false
                          set index of w to 1
                          activate
                          return (tty of selected tab of front window is "\(tty)")
                      end if
                  end repeat
              end repeat
              return false
          end tell
          end timeout
          """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
          continuation.resume(
            throwing: IntegrationError(
              message:
                "Terminal navigation failed: \(error[NSAppleScript.errorMessage] ?? "Allow Terminal access in System Settings → Privacy & Security → Automation.")"
            ))
          return
        }
        guard result?.booleanValue == true, terminal.isLive else {
          continuation.resume(
            throwing: IntegrationError(
              message: "The exact Terminal tab could not be verified. Its alert remains active."))
          return
        }
        continuation.resume(returning: true)
      }
    }
  }
}

final class CodexReader: @unchecked Sendable {
  private var offsets: [String: UInt64] = [:]
  private var pending: [String: Data] = [:]
  private var turns: [String: String] = [:]
  private var initial = true
  var health = "Not connected"
  func poll() -> [(Event, Bool)] {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let path = root.appendingPathComponent("state_5.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      if db != nil { sqlite3_close(db) }
      health = "Codex database unavailable"
      return []
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 100)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let query =
      "SELECT id,rollout_path,cwd,title FROM threads WHERE archived=0 AND updated_at > unixepoch()-86400 ORDER BY updated_at DESC LIMIT 64"
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
      health = "Codex format changed; observation paused"
      return []
    }
    var events: [(Event, Bool)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      func str(_ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
      }
      let id = str(0)
      let file = str(1)
      let cwd = str(2)
      let title = str(3)
      guard let handle = FileHandle(forReadingAtPath: file) else { continue }
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      var offset = offsets[id] ?? 0
      let first = offsets[id] == nil
      if offset > size {
        offset = 0
        pending[id] = nil
      }
      // Read only the tail when attaching to an old conversation. Never manufacture alerts from old history.
      let clipped = first && size > 2_097_152
      if clipped { offset = size - 2_097_152 }
      guard offset < size else { continue }
      try? handle.seek(toOffset: offset)
      guard let chunk = try? handle.read(upToCount: 2_097_152), !chunk.isEmpty else { continue }
      offsets[id] = offset + UInt64(chunk.count)
      var data = pending[id] ?? Data()
      data.append(chunk)
      let lines = data.split(separator: 10, omittingEmptySubsequences: false)
      pending[id] = Data(lines.last ?? Data.SubSequence())
      for (index, line) in lines.dropLast().enumerated() {
        if clipped && index == 0 { continue }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
          let p = obj["payload"] as? [String: Any]
        else { continue }
        let outer = obj["type"] as? String ?? ""
        let type = p["type"] as? String ?? ""
        let stamp = obj["timestamp"] as? String ?? ""
        var kind: String?
        var prompt: String?
        if outer == "event_msg" {
          switch type {
          case "task_started":
            kind = "turnStarted"
            turns[id] = p["turn_id"] as? String
          case "task_complete": kind = "ready"
          case "turn_aborted": kind = "unknown"
          case "user_message":
            prompt = p["message"] as? String
            kind = "prompt"
          default: break
          }
        } else if outer == "response_item", type == "message", p["role"] as? String == "user" {
          let content = p["content"] as? [[String: Any]] ?? []
          let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
          if !text.hasPrefix("<environment_context>"), !text.hasPrefix("# AGENTS.md"),
            !text.hasPrefix("<permissions instructions>")
          {
            prompt = text
            kind = "prompt"
          }
        }
        guard let kind else { continue }
        guard let date = Self.date(stamp) else { continue }
        let event = Event(
          id: "codex:\(id):\(stamp):\(kind)", provider: .codex, sessionID: id, path: cwd,
          kind: kind, date: date, turn: p["turn_id"] as? String ?? turns[id], prompt: prompt,
          title: kind == "prompt" ? nil : (first ? title : nil), source: "Codex local transcript")
        // Attach only recent conversations; old ones remain available in Codex itself.
        if date.timeIntervalSinceNow > -86400 || !first { events.append((event, first || initial)) }
      }
    }
    initial = false
    health = "Observing local conversations"
    return events.sorted { $0.0.date < $1.0.date }
  }
  static func date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}
