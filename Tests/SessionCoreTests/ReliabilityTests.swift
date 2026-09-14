import XCTest

@testable import SessionCore

final class ReliabilityTests: XCTestCase {
  func testMeaningfulLabelAfterPreambleAndFollowup() {
    XCTAssertEqual(
      Label.task(from: "okay, can you please fix the checkout screen", fallback: "Old"),
      "fix the checkout screen")
    XCTAssertEqual(
      Label.task(from: "I need you to investigate missing orders", fallback: "Old"),
      "investigate missing orders")
    XCTAssertEqual(Label.task(from: "okay lets do those", fallback: "Checkout"), "Checkout")
    XCTAssertEqual(
      Label.task(from: "This looks good, can you add order tracking", fallback: "Old"),
      "add order tracking")
    XCTAssertTrue(
      Label.task(
        from: "Review all of the checkout errors reported by customers yesterday morning",
        fallback: "Old"
      ).hasSuffix("…"))
  }
  func testOldTerminalIdentityDecodesWithoutTmuxFields() throws {
    let data = Data(#"{"pid":1,"started":2,"device":3,"tty":"/dev/ttys000"}"#.utf8)
    let identity = try JSONDecoder().decode(TerminalIdentity.self, from: data)
    XCTAssertNil(identity.tmuxPane)
    XCTAssertNil(identity.tmuxSocket)
  }
  func testMixedSessionsSurviveRestartAndOverflowWithoutMoving() throws {
    var board = Board()
    let date = Date(timeIntervalSince1970: 1000)
    for i in 0..<17 {
      board.apply(
        Event(
          provider: i < 15 ? .claude : .codex, sessionID: "\(i)", path: "/work/example-app",
          kind: "prompt", date: date))
    }
    let original = Dictionary(uniqueKeysWithValues: board.visible.map { ($0.id, $0.slot) })
    board = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
    for i in 17..<80 {
      board.apply(
        Event(
          provider: .claude, sessionID: "\(i)", path: "/personal/another-app", kind: "prompt",
          date: date))
    }
    XCTAssertEqual(board.pageCount, 3)
    XCTAssertEqual(Set(board.visible.map(\.slot)).count, 80)
    for (id, slot) in original { XCTAssertEqual(board.sessions[id]?.slot, slot) }
  }
  func testFullEscalationScheduleAndSeenCancellation() {
    var board = Board()
    let start = Date(timeIntervalSince1970: 1000)
    board.apply(
      Event(provider: .claude, sessionID: "one", path: "/app", kind: "waiting", date: start))
    var deliveryTimes: [Int] = []
    for second in 1...900 {
      if !board.tick(seconds: 1, now: start.addingTimeInterval(Double(second))).isEmpty {
        deliveryTimes.append(second)
      }
      if second == 300 { XCTAssertEqual(board.visible[0].alert?.stage(gentle: false), 3) }
    }
    XCTAssertEqual(deliveryTimes, [180, 600, 900])
    board.seen("claude:one")
    for second in 901...1300 {
      XCTAssertTrue(board.tick(seconds: 1, now: start.addingTimeInterval(Double(second))).isEmpty)
    }
  }
}
