import Foundation

public enum HookConfiguration {
  public static func merge(
    _ original: [String: Any], events: [String], command: String, install: Bool
  ) throws -> [String: Any] {
    func invalid() -> NSError {
      NSError(
        domain: "HookConfiguration", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The existing hook configuration has an unfamiliar format. No settings were changed."
        ])
    }
    var result = original
    if original["hooks"] != nil && !(original["hooks"] is [String: Any]) { throw invalid() }
    var hooks = original["hooks"] as? [String: Any] ?? [:]
    for event in events {
      if hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw invalid() }
      var groups: [[String: Any]] = []
      for entry in hooks[event] as? [[String: Any]] ?? [] {
        guard let actions = entry["hooks"] as? [[String: Any]] else { throw invalid() }
        var kept = entry
        let remaining = actions.filter { ($0["command"] as? String) != command }
        if !remaining.isEmpty {
          kept["hooks"] = remaining
          groups.append(kept)
        }
      }
      if install {
        groups.append(["hooks": [["type": "command", "command": command, "timeout": 2]]])
      }
      if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
    }
    result["hooks"] = hooks
    return result
  }
}
