import XCTest

@testable import SessionCore

final class ReconciliationTests: XCTestCase {
  func testStaleWorkingAndWaitingExpireButRecentSessionsStay() {
    let now = Date()
    var board = Board()
    for state in ["working", "waiting", "ready"] {
      board.apply(
        Event(
          provider: .codex, sessionID: state, path: "/old", kind: state,
          date: now.addingTimeInterval(-90000)))
    }
    board.apply(
      Event(provider: .codex, sessionID: "current", path: "/current", kind: "working", date: now))
    board.reconcile(now: now)
    XCTAssertEqual(board.visible.map(\.providerID), ["current"])
    XCTAssertNil(board.sessions["codex:waiting"]?.alert)
    board.apply(
      Event(provider: .codex, sessionID: "working", path: "/old", kind: "prompt", date: now))
    XCTAssertEqual(board.visible.count, 2)
    XCTAssertEqual(Set(board.visible.map(\.slot)).count, 2)
  }
  func testBackgroundClaudeDoesNotRemoveInteractiveSameProject() {
    var board = Board()
    for id in ["interactive", "background"] {
      board.apply(Event(provider: .claude, sessionID: id, path: "/same-project", kind: "waiting"))
    }
    board.reconcile(now: Date(), backgroundClaudeIDs: ["background"])
    XCTAssertEqual(board.visible.map(\.providerID), ["interactive"])
    XCTAssertNil(board.sessions["claude:background"]?.alert)
  }
  func testPinnedStaleTaskBecomesUnknownWithoutAlert() {
    var board = Board()
    board.apply(
      Event(
        provider: .codex, sessionID: "one", path: "/old", kind: "waiting",
        date: Date().addingTimeInterval(-90000)))
    board.sessions["codex:one"]?.pinned = true
    board.reconcile(now: Date())
    XCTAssertEqual(board.visible.first?.state, .unknown)
    XCTAssertNil(board.visible.first?.alert)
  }
  func testCodexPromptWithoutTurnCanAcceptRealTurn() {
    var board = Board()
    board.apply(
      Event(provider: .codex, sessionID: "one", path: "/app", kind: "prompt", turn: "old"))
    board.apply(
      Event(provider: .codex, sessionID: "one", path: "/app", kind: "prompt", prompt: "New request")
    )
    board.apply(
      Event(provider: .codex, sessionID: "one", path: "/app", kind: "waiting", turn: "new"))
    XCTAssertEqual(board.visible.first?.state, .waiting)
    XCTAssertEqual(board.visible.first?.turn, "new")
  }
}
