import AppKit
import CPlatform
import SessionCore

extension SessionState {
  var color: NSColor {
    switch self {
    case .working: return NSColor(red: 0.36, green: 0.65, blue: 1, alpha: 1)
    case .waiting: return NSColor(red: 1, green: 0.72, blue: 0.24, alpha: 1)
    case .ready: return NSColor(red: 0.35, green: 0.84, blue: 0.61, alpha: 1)
    case .failed: return NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
    default: return .lightGray
    }
  }
}
@MainActor final class DeckController {
  private var device: UnsafeMutableRawPointer?
  private var cache: [Int: Data] = [:]
  private var descriptions: [Int: String] = [:]
  private var routing = KeyRouting()
  var action: ((KeyRouting.Action) -> Void)?
  var inputObserved: ((Int) -> Void)?
  var status = "Disconnected"
  var connected: Bool { device != nil && sc_deck_connected(device) == 1 }
  func connect() {
    if connected { return }
    disconnect()
    var error: Int32 = 0
    device = sc_deck_open(
      { context, key, down in
        guard let context else { return }
        let controller = Unmanaged<DeckController>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
          if down != 0 { controller.inputObserved?(Int(key)) }
          if let action = controller.routing.input(
            key: Int(key), down: down != 0, uptime: ProcessInfo.processInfo.systemUptime)
          {
            controller.action?(action)
          }
        }
      }, Unmanaged.passUnretained(self).toOpaque(), &error)
    status =
      device != nil
      ? "Stream Deck XL connected"
      : (error == -1
        ? "Stream Deck XL not found" : "XL unavailable (\(error)); quit the other controller")
  }
  func disconnect() {
    if let device { sc_deck_close(device) }
    device = nil
    routing.disconnect()
    cache.removeAll()
    descriptions.removeAll()
    status = "Disconnected"
  }
  func brightness(_ value: Int) { if connected { _ = sc_deck_brightness(device, Int32(value)) } }
  func draw(board: Board, page: Int, now: Date) {
    guard connected else { return }
    let sessions = board.page(page)
    let unseen = board.visible.filter { $0.alert?.active(at: now) == true }
    let spare = unseen.contains { ($0.alert?.age ?? 0) >= 300 && $0.state != .ready }
    let pulse =
      !board.preferences.reducedMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      && !board.preferences.quiet && Int(now.timeIntervalSince1970 * 2) % 4 < 2
    for key in 0..<32 {
      let session = key < 31 ? sessions[key] : nil
      let active = session?.alert?.active(at: now) == true
      let signature: String
      if let s = session {
        signature = [
          s.id, s.project, s.task, s.state.rawValue, String(active), String(active && pulse),
          String(active && (s.alert?.age ?? 0) >= 60), String(board.preferences.quiet),
        ].joined(separator: "\u{0}")
      } else {
        signature = "\(key):\(page):\(board.pageCount):\(unseen.count):\(spare):\(spare && pulse)"
      }
      if descriptions[key] == signature { continue }
      let data = KeyRenderer.jpeg(
        session: session, index: key, page: page, pages: board.pageCount, attention: unseen.count,
        pulse: pulse, spare: spare, quiet: board.preferences.quiet)
      if data == cache[key] {
        // Identical pixels can represent a different session with identical labels.
        descriptions[key] = signature
        routing.didRender(key: key, session: session?.id)
        continue
      }
      let result = data.withUnsafeBytes {
        sc_deck_image(
          device, Int32(key), $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count))
      }
      if result != 0 {
        status = "XL write failed (\(result)); reconnecting"
        disconnect()
        return
      }
      cache[key] = data
      descriptions[key] = signature
      routing.didRender(key: key, session: session?.id)
    }
  }
}
@MainActor enum KeyRenderer {
  static func jpeg(
    session: Session?, index: Int, page: Int, pages: Int, attention: Int, pulse: Bool, spare: Bool,
    quiet: Bool
  ) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // XL expects a 180-degree rotation.
    let transform = NSAffineTransform()
    transform.translateX(by: 96, yBy: 96)
    transform.rotate(byDegrees: 180)
    transform.concat()
    NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 96, height: 96).fill()
    if let s = session {
      let active = s.alert?.active(at: Date()) == true
      let full = active && (s.alert?.age ?? 0) >= 60 && s.state != .ready && pulse && !quiet
      if full {
        s.state.color.withAlphaComponent(0.32).setFill()
        NSRect(x: 0, y: 0, width: 96, height: 96).fill()
      }
      s.state.color.withAlphaComponent(active && pulse ? 1 : 0.6).setFill()
      NSRect(x: 0, y: 89, width: 96, height: 7).fill()
      text(
        s.provider.badge, rect: NSRect(x: 5, y: 73, width: 25, height: 13), size: 10,
        color: .lightGray)
      text(
        s.state == .working
          ? "RUN" : s.state == .waiting ? "WAIT" : s.state == .ready ? "READY" : "?",
        rect: NSRect(x: 34, y: 73, width: 57, height: 13), size: 10, color: s.state.color,
        alignment: .right)
      fitted(s.project, rect: NSRect(x: 5, y: 36, width: 86, height: 34), maxSize: 16, minSize: 11)
      fitted(
        s.task, rect: NSRect(x: 5, y: 5, width: 86, height: 28), maxSize: 11, minSize: 9,
        color: .lightGray)
    } else if index == 31 {
      text(
        "\(attention)", rect: NSRect(x: 4, y: 48, width: 88, height: 30), size: 26,
        color: attention > 0 ? SessionState.waiting.color : .white)
      text("NEED YOU", rect: NSRect(x: 4, y: 32, width: 88, height: 13), size: 9, color: .lightGray)
      text(
        "\(page+1) / \(pages)  →", rect: NSRect(x: 4, y: 10, width: 88, height: 17), size: 12,
        color: .white)
    } else if spare && attention > 0 {
      if pulse {
        SessionState.waiting.color.withAlphaComponent(0.18).setFill()
        NSRect(x: 0, y: 0, width: 96, height: 96).fill()
      }
      text(
        "!", rect: NSRect(x: 4, y: 40, width: 88, height: 34), size: 30,
        color: SessionState.waiting.color)
      text(
        "NEEDS YOU", rect: NSRect(x: 4, y: 20, width: 88, height: 16), size: 10, color: .lightGray)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
  }
  static func fitted(
    _ string: String, rect: NSRect, maxSize: CGFloat, minSize: CGFloat, color: NSColor = .white
  ) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    for size in stride(from: maxSize, through: minSize, by: -1) {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        .paragraphStyle: style,
      ]
      let bound = (string as NSString).boundingRect(
        with: NSSize(width: rect.width, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
      if bound.height <= rect.height && bound.width <= rect.width {
        (string as NSString).draw(
          with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
        return
      }
    }
    // Explicit ellipsis, with the complete name available in the native inspector.
    style.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: minSize, weight: .semibold), .foregroundColor: color,
      .paragraphStyle: style,
    ]
    (string as NSString).draw(
      with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
  }
  static func text(
    _ string: String, rect: NSRect, size: CGFloat, color: NSColor,
    alignment: NSTextAlignment = .center
  ) {
    let p = NSMutableParagraphStyle()
    p.alignment = alignment
    (string as NSString).draw(
      in: rect,
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        .paragraphStyle: p,
      ])
  }
}
