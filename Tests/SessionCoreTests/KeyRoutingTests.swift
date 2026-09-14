import XCTest

@testable import SessionCore

final class KeyRoutingTests: XCTestCase {
  func testPendingLayoutDoesNotChangeDisplayedTarget() {
    var routing = KeyRouting()
    routing.didRender(key: 0, session: "claude:first")
    XCTAssertNil(routing.input(key: 0, down: true, uptime: 10))
    routing.didRender(key: 0, session: "codex:replacement")
    XCTAssertEqual(routing.input(key: 0, down: false, uptime: 10.2), .open("claude:first"))
    XCTAssertNil(routing.input(key: 0, down: true, uptime: 11))
    XCTAssertEqual(routing.input(key: 0, down: false, uptime: 11.2), .open("codex:replacement"))
  }
  func testHoldOnlyInspectsAndDuplicateDownDoesNotResetTimer() {
    var routing = KeyRouting()
    routing.didRender(key: 3, session: "claude:checkout")
    _ = routing.input(key: 3, down: true, uptime: 0)
    _ = routing.input(key: 3, down: true, uptime: 0.6)
    XCTAssertEqual(routing.input(key: 3, down: false, uptime: 0.8), .inspect("claude:checkout"))
    XCTAssertNil(routing.input(key: 3, down: false, uptime: 1))
  }
  func testDisconnectCancelsHeldKeysAndUnrenderedKeysDoNothing() {
    var routing = KeyRouting()
    XCTAssertNil(routing.input(key: 5, down: true, uptime: 1))
    routing.didRender(key: 5, session: "old")
    _ = routing.input(key: 5, down: true, uptime: 2)
    routing.disconnect()
    routing.didRender(key: 5, session: "new")
    XCTAssertNil(routing.input(key: 5, down: false, uptime: 2.2))
  }
  func testGlobalAndSpareKeyActions() {
    var routing = KeyRouting()
    routing.didRender(key: 31, session: nil)
    _ = routing.input(key: 31, down: true, uptime: 0)
    XCTAssertEqual(routing.input(key: 31, down: false, uptime: 0.2), .nextPage)
    _ = routing.input(key: 31, down: true, uptime: 1)
    XCTAssertEqual(routing.input(key: 31, down: false, uptime: 2), .attention)
    routing.didRender(key: 9, session: nil)
    _ = routing.input(key: 9, down: true, uptime: 3)
    XCTAssertEqual(routing.input(key: 9, down: false, uptime: 3.1), .attention)
  }
  func testNavigationCannotAcknowledgeANewerAlert() {
    var board = Board()
    board.apply(
      Event(
        provider: .claude, sessionID: "one", path: "/app", kind: "waiting", requestID: "request-a"))
    let captured = board.visible[0].alert?.id
    board.apply(
      Event(
        provider: .claude, sessionID: "one", path: "/app", kind: "waiting", requestID: "request-b"))
    board.seen("claude:one", matching: captured)
    XCTAssertEqual(board.visible[0].alert?.seen, false)
    board.seen("claude:one", matching: board.visible[0].alert?.id)
    XCTAssertEqual(board.visible[0].alert?.seen, true)
  }
  func testRepeatedPermissionNamesAcrossTurnsRemainIndependent() {
    var board = Board()
    board.apply(Event(provider: .claude, sessionID: "one", path: "/app", kind: "prompt", turn: "a"))
    board.apply(
      Event(
        provider: .claude, sessionID: "one", path: "/app", kind: "waiting", turn: "a",
        requestID: "wait:Bash"))
    let captured = board.visible[0].alert?.id
    board.apply(Event(provider: .claude, sessionID: "one", path: "/app", kind: "prompt", turn: "b"))
    board.apply(
      Event(
        provider: .claude, sessionID: "one", path: "/app", kind: "waiting", turn: "b",
        requestID: "wait:Bash"))
    board.seen("claude:one", matching: captured)
    XCTAssertEqual(board.visible[0].alert?.seen, false)
  }
  func testLateToolActivityCannotResurrectOldTurn() {
    var board = Board()
    board.apply(
      Event(provider: .codex, sessionID: "one", path: "/app", kind: "turnStarted", turn: "a"))
    board.apply(
      Event(provider: .codex, sessionID: "one", path: "/app", kind: "turnStarted", turn: "b"))
    board.apply(Event(provider: .codex, sessionID: "one", path: "/app", kind: "waiting", turn: "b"))
    board.apply(Event(provider: .codex, sessionID: "one", path: "/app", kind: "working", turn: "a"))
    XCTAssertEqual(board.visible[0].state, .waiting)
    XCTAssertEqual(board.visible[0].turn, "b")
  }

  func testNextAndAcknowledgmentKeepTheTaskLabel() {
    for prompt in ["next", "next please", "ok this seems good. next", "Yes, go ahead!"] {
      XCTAssertEqual(Label.task(from: prompt, fallback: "Fix checkout"), "Fix checkout")
    }
    XCTAssertEqual(
      Label.task(from: "Next implement checkout", fallback: "Fix login"), "Next implement checkout")
  }

}
