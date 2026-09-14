import CPlatform
import Darwin
import Foundation
import SessionCore

func terminalIdentity() -> TerminalIdentity? {
  var pid = getppid()
  for _ in 0..<16 {
    var p = SCProcess()
    guard sc_process(pid, &p) == 1 else { break }
    let name = withUnsafePointer(to: &p.name) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    if name.lowercased().contains("claude"), p.terminal != UInt64(UInt32.max), p.terminal != 0 {
      let tty = withUnsafePointer(to: &p.tty) {
        $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
      }
      if tty.hasPrefix("/dev/ttys") {
        return TerminalIdentity(
          pid: pid, started: p.started, device: p.terminal, tty: tty,
          tmuxPane: ProcessInfo.processInfo.environment["TMUX_PANE"],
          tmuxSocket: ProcessInfo.processInfo.environment["TMUX"]?.split(separator: ",").first.map(
            String.init))
      }
    }
    guard p.parent > 1, p.parent != pid else { break }
    pid = p.parent
  }
  return nil
}
// Ignore malformed/oversized input and always exit successfully: this helper never blocks an agent decision.
let provider: Provider = CommandLine.arguments.contains("--codex") ? .codex : .claude
let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
if data.count <= 1_048_576,
  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
  let session = payload["session_id"] as? String
{
  let name = payload["hook_event_name"] as? String ?? ""
  var kind: String?
  switch name {
  case "SessionStart": kind = "start"
  case "SessionEnd": kind = "ended"
  case "UserPromptSubmit": kind = "prompt"
  case "Stop": kind = "ready"
  case "StopFailure": kind = "failed"
  case "Interrupt": kind = "unknown"
  case "PermissionRequest", "Elicitation": kind = "waiting"
  case "PreToolUse":
    kind =
      (["AskUserQuestion", "request_user_input", "request_user_input_async"].contains(
        payload["tool_name"] as? String ?? "")) ? "waiting" : "working"
  case "PostToolUse", "PostToolUseFailure", "ElicitationResult": kind = "working"
  case "Notification":
    let subtype = payload["notification_type"] as? String ?? ""
    if ["permission_prompt", "idle_prompt", "elicitation_dialog"].contains(subtype) {
      kind = "waiting"
    }
  default: break
  }
  if let kind {
    let request =
      (payload["tool_use_id"] as? String)
      ?? (kind == "waiting"
        ? "wait:\(payload["notification_type"] as? String ?? payload["tool_name"] as? String ?? name)"
        : nil)
    let event = Event(
      provider: provider, sessionID: session, path: payload["cwd"] as? String ?? "", kind: kind,
      turn: payload["turn_id"] as? String,
      prompt: payload["prompt"] as? String ?? payload["user_prompt"] as? String
        ?? ((payload["message"] as? [String: Any])?["content"] as? String)
          ?? ((payload["message"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap {
            $0["text"] as? String
          }.joined(separator: "\n"),
      terminal: provider == .claude ? terminalIdentity() : nil, requestID: request)
    try? Spool.write(event)
  }
}
exit(0)
