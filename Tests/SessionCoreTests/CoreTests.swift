import XCTest

@testable import SessionCore

final class CoreTests: XCTestCase {
  let base = Date(timeIntervalSince1970: 1000)
  func event(
    _ id: String = "one", _ kind: String = "prompt", seconds: Double = 0, turn: String? = nil,
    prompt: String? = nil, provider: Provider = .claude, request: String? = nil
  ) -> Event {
    Event(
      id: UUID().uuidString, provider: provider, sessionID: id, path: "/work/example-app",
      kind: kind, date: base.addingTimeInterval(seconds), turn: turn, prompt: prompt,
      requestID: request)
  }
  func testUnknownProjectAndSameProjectSessions() {
    var b = Board()
    b.apply(event("one", prompt: "Fix login screen"))
    b.apply(event("two", prompt: "Build checkout"))
    b.apply(event("one", provider: .codex))
    XCTAssertEqual(b.visible.count, 3)
    XCTAssertEqual(Set(b.visible.map(\.slot)).count, 3)
    XCTAssertEqual(b.visible[0].project, "example-app")
  }
  func testHistoricalReservationsRelease() {
    var b = Board()
    for i in 0..<100 {
      b.apply(event("\(i)"))
      XCTAssertEqual(b.visible.first?.slot, 0)
      b.apply(event("\(i)", "ended", seconds: 1))
    }
    XCTAssertTrue(b.visible.isEmpty)
  }
  func testPagingAndStablePlacement() {
    var b = Board()
    for i in 0..<64 { b.apply(event("\(i)")) }
    XCTAssertEqual(b.pageCount, 3)
    XCTAssertEqual(b.page(0).compactMap { $0 }.count, 31)
    XCTAssertEqual(b.page(2).compactMap { $0 }.count, 2)
    let captured = b.page(0)[3]!.id
    b.apply(event("new"))
    XCTAssertEqual(b.page(0)[3]?.id, captured)
    b.move(captured, to: 32)
    XCTAssertEqual(Set(b.visible.map(\.slot)).count, 65)
  }
  func testContinuePreservesMeaningfulLabel() {
    var b = Board()
    b.apply(event(prompt: "Fix the checkout payment screen"))
    b.apply(event(seconds: 1, prompt: "continue"))
    XCTAssertEqual(b.visible[0].task, "Fix the checkout payment screen")
    XCTAssertEqual(b.visible[0].prompts.last?.text, "continue")
  }
  func testSeenKeepsWaitingAndNewRequestRearms() {
    var b = Board()
    b.apply(event("one", "waiting", request: "a"))
    b.seen("claude:one")
    XCTAssertEqual(b.visible[0].state, .waiting)
    XCTAssertEqual(b.visible[0].alert?.seen, true)
    b.apply(event("one", "waiting", seconds: 1, request: "b"))
    XCTAssertEqual(b.visible[0].alert?.seen, false)
  }
  func testDuplicateAndLateTurnCannotRegress() {
    var b = Board()
    let first = event(turn: "a", prompt: "First prompt")
    b.apply(first)
    b.apply(first)
    XCTAssertEqual(b.visible[0].prompts.count, 1)
    b.apply(event(seconds: 2, turn: "b"))
    b.apply(event("one", "ready", seconds: 3, turn: "a"))
    XCTAssertEqual(b.visible[0].state, .working)
    b.apply(event("one", "ready", seconds: 1, turn: "b"))
    XCTAssertEqual(b.visible[0].state, .working)
  }
  func testAttentionScheduleQuietSnoozeAndSleep() {
    var b = Board()
    b.apply(event("one", "waiting"))
    var notifications = 0
    for i in 1...180 {
      notifications += b.tick(seconds: 1, now: base.addingTimeInterval(Double(i))).count
    }
    XCTAssertEqual(notifications, 1)
    XCTAssertTrue(b.tick(seconds: 1, now: base.addingTimeInterval(181)).isEmpty)
    b.snooze("claude:one", until: base.addingTimeInterval(1000))
    let age = b.visible[0].alert!.age
    _ = b.tick(seconds: 1, now: base.addingTimeInterval(200))
    XCTAssertEqual(b.visible[0].alert?.age, age)
    b.boardQuietForTest()
    for i in 1000...1600 {
      XCTAssertTrue(b.tick(seconds: 1, now: base.addingTimeInterval(Double(i))).isEmpty)
    }
  }
  func testHistoricalAttachDoesNotAlert() {
    var b = Board()
    b.apply(event("one", "ready"), historical: true)
    XCTAssertEqual(b.visible[0].alert?.seen, true)
  }
  func testToolFailureIsNotSessionFailure() {
    var b = Board()
    b.apply(event())
    b.apply(event("one", "toolFailure", seconds: 1))
    XCTAssertEqual(b.visible[0].state, .working)
  }
  func testStorageRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try Store(url: folder.appendingPathComponent("db.sqlite"))
    var b = Board()
    b.apply(event(prompt: "A real task"))
    b.seen("claude:one")
    try store.save(b)
    let loaded = try store.load()
    XCTAssertEqual(loaded.sessions, b.sessions)
  }
  func testHookRepairPreservesOtherSettings() throws {
    let original: [String: Any] = [
      "theme": "dark",
      "hooks": [
        "Stop": [["matcher": "*", "hooks": [["type": "command", "command": "my-existing-hook"]]]]
      ],
    ]
    let one = try HookConfiguration.merge(
      original, events: ["Stop"], command: "our-reporter", install: true)
    let two = try HookConfiguration.merge(
      one, events: ["Stop"], command: "our-reporter", install: true)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: one, options: .sortedKeys),
      try JSONSerialization.data(withJSONObject: two, options: .sortedKeys))
    let removed = try HookConfiguration.merge(
      two, events: ["Stop"], command: "our-reporter", install: false)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: original, options: .sortedKeys),
      try JSONSerialization.data(withJSONObject: removed, options: .sortedKeys))
    XCTAssertThrowsError(
      try HookConfiguration.merge(
        ["hooks": ["Stop": "unfamiliar"]], events: ["Stop"], command: "reporter", install: true))
  }
  func testGeneratedTranscriptTextDoesNotBecomeTaskLabel() {
    XCTAssertEqual(
      Label.task(from: "[Image: source: /tmp/image.png]", fallback: "Checkout"), "Checkout")
    XCTAssertEqual(
      Label.task(
        from: "This session is being continued from a previous conversation", fallback: "Checkout"),
      "Checkout")
  }
  func testDifferentFoldersKeepFullPaths() {
    var b = Board()
    var a = event()
    a.path = "/personal/example-app"
    var c = event("two")
    c.path = "/work/example-app"
    b.apply(a)
    b.apply(c)
    XCTAssertNotEqual(b.visible[0].path, b.visible[1].path)
  }
}
extension Board { fileprivate mutating func boardQuietForTest() { preferences.quiet = true } }
