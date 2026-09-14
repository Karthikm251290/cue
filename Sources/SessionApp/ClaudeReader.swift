import CPlatform
import Foundation
import SessionCore

/// Reads only the public fields needed for identity; peer keys and messaging sockets are never opened.
final class ClaudeReader: @unchecked Sendable {
  private var stamps: [String: Date] = [:]
  private var attached = Set<String>()
  private var transcriptStamps: [String: Date] = [:]
  private var historyStamp: Date?
  private var identities: [String: (String, TerminalIdentity)] = [:]
  func poll() -> [(Event, Bool)] {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("sessions"),
        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    var output: [(Event, Bool)] = []
    for file in files where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
        let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let pid = row["pid"] as? Int32, let id = row["sessionId"] as? String,
        let cwd = row["cwd"] as? String
      else { continue }
      var info = SCProcess()
      guard sc_process(pid, &info) == 1 else { continue }
      let started = Double(info.started) / 1_000_000
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
      guard let expected = (row["procStart"] as? String).flatMap({ formatter.date(from: $0) }),
        abs(expected.timeIntervalSince1970 - started) < 2
      else { continue }
      let tty = withUnsafePointer(to: &info.tty) {
        $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
      }
      let direct = row["tmux"] == nil && tty.hasPrefix("/dev/ttys")
      let terminal = TerminalIdentity(
        pid: pid, started: info.started, device: info.terminal, tty: tty,
        tmuxPane: (row["tmux"] as? String)?.split(separator: ".").last.map(String.init))
      identities[id] = (cwd, terminal)
      let first = !attached.contains(id)
      let stamp =
        (row["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        ?? Date(timeIntervalSince1970: started)
      if stamps[id] != stamp || first {
        stamps[id] = stamp
        attached.insert(id)
        let status = row["status"] as? String ?? ""
        // The registry's idle value does not prove a completed answer or a permission request.
        let kind = status == "busy" ? "working" : status == "idle" ? "idle" : "unknown"
        let title = row["nameSource"] as? String == "derived" ? nil : row["name"] as? String
        output.append(
          (
            Event(
              id: "claude-registry:\(id):\(stamp.timeIntervalSince1970)", provider: .claude,
              sessionID: id, path: cwd, kind: kind, date: stamp, title: title, terminal: terminal,
              source: !direct
                ? "Claude registry · tmux" : "Claude session registry"),
            true
          ))
      }
      let folder = cwd.map { char -> Character in char.isLetter || char.isNumber ? char : "-" }
        .reduce(into: "") { $0.append($1) }
      let transcript = root.appendingPathComponent("projects/\(folder)/\(id).jsonl")
      guard
        let modified = try? transcript.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate, transcriptStamps[id] != modified,
        let handle = FileHandle(forReadingAtPath: transcript.path)
      else { continue }
      transcriptStamps[id] = modified
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      let offset = size > 1_048_576 ? size - 1_048_576 : 0
      try? handle.seek(toOffset: offset)
      guard let tail = try? handle.read(upToCount: 1_048_576) else { continue }
      var prompts: [Event] = []
      for (index, line) in tail.split(separator: 10).enumerated() {
        if offset > 0 && index == 0 { continue }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
          object["type"] as? String == "user", object["isSidechain"] as? Bool != true,
          let message = object["message"] as? [String: Any]
        else { continue }
        let content = message["content"]
        let text =
          (content as? String) ?? (content as? [[String: Any]])?.filter {
            $0["type"] as? String == "text"
          }.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        guard !text.isEmpty, !text.hasPrefix("<"),
          !text.hasPrefix("This session is being continued"), !text.hasPrefix("[Image:"),
          let date = (object["timestamp"] as? String).flatMap(CodexReader.date)
        else { continue }
        // Prompt history enriches labels but never infers present running/waiting status from an old message.
        prompts.append(
          Event(
            id: object["uuid"] as? String ?? "\(id):\(date.timeIntervalSince1970)",
            provider: .claude, sessionID: id, path: cwd, kind: "history", date: date, prompt: text,
            terminal: terminal, source: "Claude local transcript"))
      }
      output.append(contentsOf: prompts.suffix(30).map { ($0, true) })
    }
    let history = root.appendingPathComponent("history.jsonl")
    if let modified = try? history.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate, historyStamp != modified,
      let handle = FileHandle(forReadingAtPath: history.path)
    {
      historyStamp = modified
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      let offset = size > 2_097_152 ? size - 2_097_152 : 0
      try? handle.seek(toOffset: offset)
      if let data = try? handle.read(upToCount: 2_097_152) {
        var bySession: [String: [Event]] = [:]
        for (index, line) in data.split(separator: 10).enumerated() {
          if offset > 0 && index == 0 { continue }
          guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
            let id = row["sessionId"] as? String, let (cwd, terminal) = identities[id],
            terminal.isLive, let text = row["display"] as? String,
            let millis = row["timestamp"] as? Double
          else { continue }
          bySession[id, default: []].append(
            Event(
              id: "claude-history:\(id):\(millis)", provider: .claude, sessionID: id, path: cwd,
              kind: "history", date: Date(timeIntervalSince1970: millis / 1000), prompt: text,
              terminal: terminal, source: "Claude prompt history"))
        }
        for events in bySession.values {
          output.append(contentsOf: events.suffix(30).map { ($0, true) })
        }
      }
    }
    return output.sorted { $0.0.date < $1.0.date }
  }
}
