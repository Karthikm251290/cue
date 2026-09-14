import AppKit
import SessionCore
import XCTest

@testable import SessionApp

final class RenderingTests: XCTestCase {
  @MainActor func testAllStatesProduceXLJPEG() {
    for state in [SessionState.working, .waiting, .ready, .unknown, .failed] {
      var s = Session(
        provider: .claude, providerID: "a", path: "/work/example-app", date: Date(), slot: 0)
      s.state = state
      s.title = "Fix checkout"
      s.alert = AlertState(id: "request")
      let data = KeyRenderer.jpeg(
        session: s, index: 0, page: 0, pages: 1, attention: 1, pulse: true, spare: false,
        quiet: false)
      let image = NSBitmapImageRep(data: data)
      XCTAssertEqual(image?.pixelsWide, 96)
      XCTAssertEqual(image?.pixelsHigh, 96)
      XCTAssertEqual(Array(data.prefix(2)), [255, 216])
    }
  }
  @MainActor func testEmptyAndNavigationKeys() {
    for index in [12, 31] {
      let data = KeyRenderer.jpeg(
        session: nil, index: index, page: 1, pages: 3, attention: 2, pulse: false, spare: true,
        quiet: false)
      XCTAssertNotNil(NSBitmapImageRep(data: data))
    }
  }
}
