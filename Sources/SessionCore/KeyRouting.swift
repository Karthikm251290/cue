import Foundation

/// A press belongs to the image that was successfully written, not the next board layout.
public struct KeyRouting {
  public enum Action: Equatable {
    case open(String)
    case inspect(String)
    case nextPage
    case attention
  }
  private struct Press {
    var session: String?
    var began: TimeInterval
  }
  private var displayed: [Int: String] = [:]
  private var initialized = Set<Int>()
  private var pressed: [Int: Press] = [:]
  public init() {}

  public mutating func didRender(key: Int, session: String?) {
    guard (0..<32).contains(key) else { return }
    initialized.insert(key)
    displayed[key] = session
  }

  public mutating func input(key: Int, down: Bool, uptime: TimeInterval) -> Action? {
    guard initialized.contains(key) else { return nil }
    if down {
      if pressed[key] == nil { pressed[key] = Press(session: displayed[key], began: uptime) }
      return nil
    }
    guard let press = pressed.removeValue(forKey: key) else { return nil }
    let held = uptime - press.began >= 0.7
    if key == 31 { return held ? .attention : .nextPage }
    guard let session = press.session else { return .attention }
    return held ? .inspect(session) : .open(session)
  }

  public mutating func disconnect() {
    displayed.removeAll()
    initialized.removeAll()
    pressed.removeAll()
  }
}
