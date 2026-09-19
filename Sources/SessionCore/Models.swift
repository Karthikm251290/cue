import CPlatform
import Foundation

public enum Provider: String, Codable, CaseIterable {
  case claude, codex
  public var title: String { self == .claude ? "Claude Code" : "Codex Desktop" }
  public var badge: String { self == .claude ? "CC" : "CX" }
}
public enum SessionState: String, Codable {
  case working, waiting, ready, failed, unknown, ended, idle
  public var title: String {
    switch self {
    case .idle: return "Idle"
    case .working: return "Working"
    case .waiting: return "Needs you"
    case .ready: return "Ready"
    case .failed: return "Stopped with error"
    case .unknown: return "Status unavailable"
    case .ended: return "Ended"
    }
  }
  public var needsAttention: Bool { self == .waiting || self == .ready || self == .failed }
  public var symbol: String {
    switch self {
    case .idle: return "pause.circle"
    case .working: return "arrow.triangle.2.circlepath"
    case .waiting: return "hand.raised.fill"
    case .ready: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .unknown: return "questionmark.circle"
    case .ended: return "stop.circle"
    }
  }
}
public struct TerminalIdentity: Codable, Equatable, Sendable {
  public var pid: Int32
  public var started: UInt64
  public var device: UInt64
  public var tty: String
  public var tmuxPane: String?
  public var tmuxSocket: String?
  public init(
    pid: Int32, started: UInt64, device: UInt64, tty: String, tmuxPane: String? = nil,
    tmuxSocket: String? = nil
  ) {
    self.pid = pid
    self.started = started
    self.device = device
    self.tty = tty
    self.tmuxPane = tmuxPane
    self.tmuxSocket = tmuxSocket
  }
  public func preservingSocket(from previous: TerminalIdentity?) -> TerminalIdentity {
    var identity = self
    if tmuxPane != nil, tmuxSocket == nil, previous?.pid == pid,
      previous?.started == started, previous?.tmuxPane == tmuxPane
    {
      identity.tmuxSocket = previous?.tmuxSocket
    }
    return identity
  }
  public var isLive: Bool {
    var info = SCProcess()
    return sc_process(pid, &info) == 1 && info.started == started && info.terminal == device
  }
}
public struct Prompt: Codable, Identifiable, Equatable {
  public var id: String
  public var text: String
  public var date: Date
  public init(id: String, text: String, date: Date) {
    self.id = id
    self.text = text
    self.date = date
  }
}
public struct AlertState: Codable, Equatable {
  public var id: String
  public var age: TimeInterval = 0
  public var seen = false
  public var snoozedUntil: Date?
  public var lastNotifiedStage = 0
  public init(id: String) { self.id = id }
  public func active(at date: Date) -> Bool {
    !seen && (snoozedUntil == nil || snoozedUntil! <= date)
  }
  public func stage(gentle: Bool) -> Int {
    if gentle { return age >= 600 ? 3 : 1 }
    if age >= 600 { return 4 + Int((age - 600) / 300) }
    if age >= 300 { return 3 }
    if age >= 180 { return 2 }
    return age >= 60 ? 1 : 0
  }
}
public struct Session: Codable, Identifiable, Equatable {
  public var id: String
  public var provider: Provider
  public var providerID: String
  public var path: String
  public var title: String = "New session"
  public var customTitle: String?
  public var projectAlias: String?
  public var projectContext: String?
  public var state: SessionState = .unknown
  public var updated: Date
  public var turn: String?
  public var terminal: TerminalIdentity?
  public var prompts: [Prompt] = []
  public var alert: AlertState?
  public var slot: Int
  public var pinned = false
  public var hidden = false
  public var source: String = "Hook"
  public var project: String {
    projectAlias?.isEmpty == false
      ? projectAlias!
      : (URL(fileURLWithPath: path).lastPathComponent.isEmpty
        ? "Untitled project" : URL(fileURLWithPath: path).lastPathComponent)
        + (projectContext.map { " · " + $0 } ?? "")
  }
  public var task: String { customTitle?.isEmpty == false ? customTitle! : title }
  public init(provider: Provider, providerID: String, path: String, date: Date, slot: Int) {
    self.provider = provider
    self.providerID = providerID
    self.id = "\(provider.rawValue):\(providerID)"
    self.path = path
    self.updated = date
    self.slot = slot
  }
}
public struct Event: Codable {
  public var id: String
  public var provider: Provider
  public var sessionID: String
  public var path: String
  public var kind: String
  public var date: Date
  public var turn: String?
  public var prompt: String?
  public var title: String?
  public var terminal: TerminalIdentity?
  public var requestID: String?
  public var source: String
  public init(
    id: String = UUID().uuidString, provider: Provider, sessionID: String, path: String,
    kind: String, date: Date = Date(), turn: String? = nil, prompt: String? = nil,
    title: String? = nil, terminal: TerminalIdentity? = nil, requestID: String? = nil,
    source: String = "Hook"
  ) {
    self.id = id
    self.provider = provider
    self.sessionID = sessionID
    self.path = path
    self.kind = kind
    self.date = date
    self.turn = turn
    self.prompt = prompt
    self.title = title
    self.terminal = terminal
    self.requestID = requestID
    self.source = source
  }
}
public struct Preferences: Codable {
  public var quiet = false
  public var reducedMotion = false
  public var brightness = 45
  public var deckEnabled = false
  public init() {}
}
public enum Label {
  public static func task(from text: String, fallback: String) -> String {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let acknowledgmentWords: Set<String> = [
      "ok", "okay", "yes", "yeah", "yep", "go", "ahead", "continue", "proceed", "next",
      "please", "thanks", "thank", "you", "this", "that", "seems", "looks", "good", "great",
      "fine", "agreed", "sure", "it", "is", "now", "lets", "then",
    ]
    let tokens = normalized.lowercased().split { !$0.isLetter }.map(String.init)
    let startsAcknowledgment = [
      "ok", "okay", "yes", "yeah", "yep", "go", "continue", "proceed", "next", "thanks", "agreed",
      "sure",
    ].contains(tokens.first ?? "")
    if startsAcknowledgment && tokens.count <= 10 && tokens.allSatisfy(acknowledgmentWords.contains)
    {
      return fallback
    }
    let generic = [
      "continue", "continue.", "yes", "yes.", "go ahead", "okay", "ok", "proceed", "yes go ahead",
    ]
    guard !normalized.isEmpty, !generic.contains(normalized.lowercased()),
      !normalized.hasPrefix("<"), !normalized.hasPrefix("[Image:"),
      !normalized.hasPrefix("This session is being continued"),
      !normalized.hasPrefix("[Request interrupted")
    else { return fallback }
    // Remove conversational lead-ins without inventing a summary or sending prompts elsewhere.
    var candidate = normalized
    let prefixes = [
      #"^(?:(?:okay|ok|yes|yeah|sure|thanks)[,!. ]+)+"#,
      #"^(?:can|could|would) (?:you|yu) (?:please )?"#,
      #"^(?:i (?:want|need|would like) (?:you )?to |please |let[’']?s )"#,
    ]
    for pattern in prefixes {
      candidate = candidate.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    // A concrete request following a preamble is more useful on a small key.
    if let range = candidate.range(
      of: #"(?:[,;] |[.!?] +)(?:can|could|would) you (?:please )?"#,
      options: [.regularExpression, .caseInsensitive])
    {
      candidate = String(candidate[range.upperBound...])
    }
    let acknowledgments = [
      "go ahead", "do those", "do that", "implement it", "implement those", "continue", "proceed",
    ]
    if acknowledgments.contains(
      candidate.lowercased().trimmingCharacters(in: .punctuationCharacters))
    {
      return fallback
    }
    let sentence = candidate.components(separatedBy: "\n").first ?? candidate
    let taskTokens = sentence.split(separator: " ")
    let words = taskTokens.prefix(9).joined(separator: " ")
    return String(words.prefix(100)) + (taskTokens.count > 9 || words.count > 100 ? "…" : "")
  }
}

public struct Board: Codable {
  public var sessions: [String: Session] = [:]
  public var preferences = Preferences()
  public var processed: [String] = []
  public init() {}
  public var visible: [Session] {
    sessions.values.filter { !$0.hidden && $0.state != .ended }.sorted { $0.slot < $1.slot }
  }
  public var pageCount: Int { max(1, (visible.map(\.slot).max() ?? 0) / 31 + 1) }
  public func page(_ page: Int) -> [Session?] {
    (0..<31).map { key in visible.first { $0.slot == page * 31 + key } }
  }
  public mutating func apply(_ event: Event, historical: Bool = false) {
    guard !event.sessionID.isEmpty, !processed.contains(event.id) else { return }
    processed.append(event.id)
    if processed.count > 4096 { processed.removeFirst(processed.count - 4096) }
    let key = "\(event.provider.rawValue):\(event.sessionID)"
    let occupied = Set(visible.map(\.slot))
    let free = (0...).first { !occupied.contains($0) }!
    var s =
      sessions[key]
      ?? Session(
        provider: event.provider, providerID: event.sessionID, path: event.path, date: event.date,
        slot: free)
    if event.kind == "history" {
      if let prompt = event.prompt, !s.prompts.contains(where: { $0.id == event.id }) {
        s.prompts.append(Prompt(id: event.id, text: String(prompt.prefix(32000)), date: event.date))
        s.prompts.sort { $0.date < $1.date }
        s.prompts = Array(s.prompts.suffix(30))
        if s.customTitle == nil, let latest = s.prompts.last {
          s.title = Label.task(from: latest.text, fallback: s.title)
        }
      }
      if let terminal = event.terminal { s.terminal = terminal.preservingSocket(from: s.terminal) }
      sessions[key] = s
      return
    }
    guard event.date >= s.updated else { return }
    if let turn = event.turn, let current = s.turn, turn != current,
      !["turnStarted", "prompt", "start"].contains(event.kind)
    {
      return
    }
    if (s.state == .ended || s.hidden)
      && ["start", "prompt", "working", "turnStarted"].contains(event.kind)
    {
      s.slot = free
      s.hidden = false
    }
    if !event.path.isEmpty { s.path = event.path }
    s.updated = event.date
    s.source = event.source
    if let t = event.terminal { s.terminal = t.preservingSocket(from: s.terminal) }
    if let t = event.turn {
      s.turn = t
    } else if event.kind == "prompt" {
      // Codex prompt hooks can precede the real turn ID; do not invent an incompatible one.
      s.turn = event.provider == .claude ? event.id : nil
    }
    if let title = event.title, !title.isEmpty { s.title = title }
    if let prompt = event.prompt, !prompt.isEmpty {
      if !s.prompts.contains(where: { $0.id == event.id }) {
        s.prompts.append(Prompt(id: event.id, text: String(prompt.prefix(32000)), date: event.date))
        s.prompts = Array(s.prompts.suffix(30))
      }
      if event.title == nil { s.title = Label.task(from: prompt, fallback: s.title) }
    }
    let newState: SessionState?
    switch event.kind {
    case "idle": newState = .idle
    case "start": newState = .unknown
    case "prompt", "working", "turnStarted": newState = .working
    case "waiting": newState = .waiting
    case "ready": newState = .ready
    case "failed": newState = .failed
    case "ended": newState = .ended
    case "unknown": newState = .unknown
    default: newState = nil
    }
    if let state = newState {
      let scope = event.turn ?? s.turn ?? "session"
      let alertID =
        "\(scope):\(state.rawValue):\(event.requestID ?? event.turn ?? s.turn ?? event.id)"
      if state.needsAttention {
        if s.alert?.id != alertID || !s.state.needsAttention {
          s.alert = AlertState(id: alertID)
          s.alert?.seen = historical
        }
      } else {
        s.alert = nil
      }
      s.state = state
    }
    sessions[key] = s
    let group = sessions.values.filter {
      !$0.hidden && $0.state != .ended
        && URL(fileURLWithPath: $0.path).lastPathComponent
          == URL(fileURLWithPath: s.path).lastPathComponent
    }
    if Set(group.map(\.path)).count > 1 {
      for member in group {
        sessions[member.id]?.projectContext =
          URL(fileURLWithPath: member.path).deletingLastPathComponent().lastPathComponent
      }
    }
  }
  /// Missing completion events must not keep old tasks working indefinitely.
  /// Registry-confirmed background Claude processes are not navigable interactive sessions.
  public mutating func reconcile(now: Date, backgroundClaudeIDs: Set<String> = []) {
    for session in visible {
      let background =
        session.provider == .claude && backgroundClaudeIDs.contains(session.providerID)
      let stale = session.provider == .codex && now.timeIntervalSince(session.updated) > 86400
      guard background || stale else { continue }
      sessions[session.id]?.alert = nil
      if stale && session.pinned {
        sessions[session.id]?.state = .unknown
        sessions[session.id]?.source = "No recent activity · status unavailable"
      } else {
        sessions[session.id]?.state = .ended
      }
    }
  }
  public mutating func tick(seconds: TimeInterval, now: Date) -> [String] {
    var notify: [String] = []
    for id in Array(sessions.keys) {
      guard var s = sessions[id], var a = s.alert, a.active(at: now) else { continue }
      a.age += max(0, min(seconds, 2))
      let stage = a.stage(gentle: s.state == .ready)
      let audible =
        s.state == .ready
        ? (a.age >= 600 && a.lastNotifiedStage == 0)
        : (stage >= 2 && stage != 3 && stage > a.lastNotifiedStage)
      if audible {
        if !preferences.quiet { notify.append(id) }
        a.lastNotifiedStage = stage
      }
      s.alert = a
      sessions[id] = s
    }
    return notify
  }
  public mutating func seen(_ id: String) { sessions[id]?.alert?.seen = true }
  /// Navigation started for a particular alert; a newer request must remain unseen.
  public mutating func seen(_ id: String, matching alertID: String?) {
    guard let alertID, sessions[id]?.alert?.id == alertID else { return }
    seen(id)
  }
  public mutating func snooze(_ id: String, until: Date) {
    sessions[id]?.alert?.snoozedUntil = until
  }
  public mutating func move(_ id: String, to slot: Int) {
    guard slot >= 0, let old = sessions[id]?.slot else { return }
    if let other = visible.first(where: { $0.slot == slot && $0.id != id }) {
      sessions[other.id]?.slot = old
    }
    sessions[id]?.slot = slot
  }
}
