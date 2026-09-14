import Foundation
import SessionCore

/// Runs on the navigation queue. Commands never write to an agent's input.
enum TmuxNavigation {
  static func terminalTTY(for identity: TerminalIdentity) throws -> String {
    guard let pane = identity.tmuxPane,
      pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil,
      identity.isLive
    else {
      throw IntegrationError(
        message: "The tmux pane identity is unavailable. Its alert remains active.")
    }
    let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    guard let executable else {
      throw IntegrationError(message: "tmux was not found. Reconnect this session from Terminal.")
    }
    let prefix = identity.tmuxSocket.map { ["-S", $0] } ?? []
    func run(_ arguments: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = prefix + arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      // Drain concurrently so a large server response cannot fill the pipe.
      let result = OutputBuffer()
      output.fileHandleForReading.readabilityHandler = { handle in
        result.append(handle.availableData)
      }
      let done = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in done.signal() }
      do { try process.run() } catch {
        output.fileHandleForReading.readabilityHandler = nil
        throw error
      }
      guard done.wait(timeout: .now() + 2) == .success else {
        process.terminate()
        output.fileHandleForReading.readabilityHandler = nil
        throw IntegrationError(message: "tmux did not respond in time. Its alert remains active.")
      }
      output.fileHandleForReading.readabilityHandler = nil
      result.append(output.fileHandleForReading.readDataToEndOfFile())
      guard process.terminationStatus == 0 else {
        throw IntegrationError(
          message: "The tmux target is no longer available. Its alert remains active.")
      }
      return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let metadata = try run([
      "display-message", "-p", "-t", pane, "#{pane_tty}|#{session_id}|#{window_id}",
    ])
    .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard metadata.count == 3, metadata[0] == identity.tty,
      metadata[1].range(of: #"^\$[0-9]+$"#, options: .regularExpression) != nil,
      metadata[2].range(of: #"^@[0-9]+$"#, options: .regularExpression) != nil
    else {
      throw IntegrationError(
        message: "The tmux pane no longer matches this session. Its alert remains active.")
    }
    let clients = try run(["list-clients", "-F", "#{client_tty}|#{session_id}"])
      .split(separator: "\n").map { $0.split(separator: "|").map(String.init) }
      .filter { $0.count == 2 && $0[1] == metadata[1] }
    guard clients.count == 1,
      clients[0][0].range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil
    else {
      throw IntegrationError(
        message: clients.isEmpty
          ? "This tmux session has no attached Terminal. Attach it in Terminal, then press its key again."
          : "This tmux session has multiple attached terminals. Detach the extra client before switching from the deck."
      )
    }
    guard identity.isLive else {
      throw IntegrationError(message: "The Claude process ended before navigation.")
    }
    _ = try run(["select-window", "-t", metadata[2]])
    _ = try run(["select-pane", "-t", pane])
    let active = try run(["display-message", "-p", "-c", clients[0][0], "#{pane_id}"])
    guard active == pane, identity.isLive else {
      throw IntegrationError(
        message: "The selected tmux pane could not be verified. Its alert remains active.")
    }
    return clients[0][0]
  }
}

private final class OutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    if data.count < 1_048_576 { data.append(chunk.prefix(1_048_576 - data.count)) }
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}
