import Darwin
import ServiceManagement
import SessionCore
import SwiftUI
import UserNotifications

@MainActor final class AppModel: ObservableObject {
  @Published var board = Board()
  @Published var page = 0
  @Published var navigating = false
  @Published var navigationNote: String?
  @Published var selected: String?
  @Published var message: String?
  @Published var hardwareStatus = "Disconnected"
  @Published var codexStatus = "Connecting…"
  @Published var hooksInstalled = false
  @Published var codexHooksInstalled = false
  @Published var integrationNote: String?
  @Published var claudeHookStatus = "Setup required"
  var windowOpener: (() -> Void)?
  private var suspensionReasons = Set<String>()
  @Published var loginStatus = "Not enabled"
  private var workspaceObservers: [NSObjectProtocol] = []
  @Published var notificationStatus = "Not requested"
  var now = Date()
  @Published var showSettings = false
  let deck = DeckController()
  private let codex = CodexReader()
  private let claude = ClaudeReader()
  private var store: Store?
  private var timer: Timer?
  private var lockFile: Int32 = -1
  private var tickCount = 0
  private var lastTick = ProcessInfo.processInfo.systemUptime
  @Published var lastPhysicalKey =
    UserDefaults.standard.string(forKey: "lastPhysicalKey") ?? "No key press received yet"
  @Published var lastNavigationResult =
    UserDefaults.standard.string(forKey: "lastNavigationResult") ?? "No session switch checked yet"
  private var polling = false
  private let readerQueue = DispatchQueue(label: "SessionControl.CodexReader", qos: .utility)
  init() {
    do { try Paths.prepare() } catch { message = error.localizedDescription }
    lockFile = Darwin.open(
      Paths.root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    do {
      store = try Store(url: Paths.root.appendingPathComponent("sessions.sqlite"))
      board = try store!.load()
    } catch {
      store = nil
      message =
        "Session storage could not be loaded; the saved database was preserved: \(error.localizedDescription)"
    }
    for (id, session) in board.sessions
    where session.customTitle == nil {
      if !session.prompts.isEmpty {
        board.sessions[id]?.title = session.prompts.sorted { $0.date < $1.date }.reduce(
          "New session"
        ) {
          Label.task(from: $1.text, fallback: $0)
        }
      }
    }
    hooksInstalled = ClaudeSetup.installed()
    codexHooksInstalled = ClaudeSetup.installed(provider: .codex)
    deck.action = { [weak self] action in self?.route(action) }
    deck.inputObserved = { [weak self] key in
      let value = "Key \(key + 1) received at \(Date().formatted(date: .omitted, time: .standard))"
      self?.lastPhysicalKey = value
      UserDefaults.standard.set(value, forKey: "lastPhysicalKey")
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    refreshNotificationStatus()
    refreshLoginStatus()
    for (name, reason) in [
      (NSWorkspace.willSleepNotification, "system"),
      (NSWorkspace.screensDidSleepNotification, "display"),
      (NSWorkspace.sessionDidResignActiveNotification, "session"),
    ] {
      workspaceObservers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in Task { @MainActor in self?.suspensionReasons.insert(reason) } })
    }
    for (name, reason) in [
      (NSWorkspace.didWakeNotification, "system"),
      (NSWorkspace.screensDidWakeNotification, "display"),
      (NSWorkspace.sessionDidBecomeActiveNotification, "session"),
    ] {
      workspaceObservers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in
          Task { @MainActor in
            self?.suspensionReasons.remove(reason)
            self?.lastTick = ProcessInfo.processInfo.systemUptime
          }
        })
    }
    tick()
  }
  var attention: [Session] {
    board.visible.filter { $0.alert?.active(at: now) == true }.sorted {
      ($0.alert?.age ?? 0) > ($1.alert?.age ?? 0)
    }
  }
  func tick() {
    now = Date()
    tickCount += 1
    let uptime = ProcessInfo.processInfo.systemUptime
    let elapsed = uptime - lastTick
    lastTick = uptime
    drain()
    // A long gap (sleep/lock) contributes no alert age and never replays missed sounds.
    let notified =
      board.visible.contains(where: { $0.alert?.active(at: now) == true })
      ? board.tick(seconds: elapsed < 3 && suspensionReasons.isEmpty ? elapsed : 0, now: now) : []
    if !notified.isEmpty { notify(notified) }
    if tickCount % 4 == 1 { pollCodex() }
    if board.preferences.deckEnabled {
      if !deck.connected && tickCount % 6 == 1 {
        deck.connect()
        deck.brightness(board.preferences.brightness)
      }
      deck.draw(board: board, page: page, now: now)
    }
    if hardwareStatus != deck.status { hardwareStatus = deck.status }
    if tickCount % 10 == 0 { save() }
    if tickCount % 20 == 0 {
      refreshNotificationStatus()
      for session in board.visible
      where session.provider == .claude && session.terminal != nil
        && session.terminal?.isLive == false
      {
        board.sessions[session.id]?.state = .ended
        board.sessions[session.id]?.alert = nil
      }
    }
    if tickCount % 120 == 0 {
      for s in board.sessions.values
      where !s.pinned && s.updated.timeIntervalSinceNow < -604800 && (s.state == .ended || s.hidden)
      { board.sessions.removeValue(forKey: s.id) }
      for s in board.visible
      where s.provider == .codex && !s.pinned && [.ready, .idle, .unknown].contains(s.state)
        && s.updated.timeIntervalSinceNow < -86400
      {
        board.sessions[s.id]?.state = .ended
        board.sessions[s.id]?.alert = nil
      }
    }
    if page >= board.pageCount { page = board.pageCount - 1 }
  }
  private func drain() {
    let overflow = Paths.root.appendingPathComponent("event-overflow")
    if FileManager.default.fileExists(atPath: overflow.path), integrationNote == nil {
      integrationNote =
        "The event queue overflowed while monitoring was unavailable. Some session states may be stale; send a new prompt to reconcile them."
    }
    let latest = UserDefaults.standard.object(forKey: "lastHook.claude") as? Date
    let hookStatus =
      latest != nil
      ? "Last event: \(latest!.formatted(date: .abbreviated, time: .shortened))"
      : hooksInstalled ? "Installed · awaiting first event" : "Setup required"
    if claudeHookStatus != hookStatus { claudeHookStatus = hookStatus }
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: Paths.spool, includingPropertiesForKeys: [.fileSizeKey])
    else { return }
    let batch = files.filter { $0.pathExtension == "json" }.sorted {
      $0.lastPathComponent < $1.lastPathComponent
    }.prefix(200)
    var consumed: [URL] = []
    for file in batch {
      guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= 1_048_576
      else {
        try? FileManager.default.removeItem(at: file)
        continue
      }
      guard let data = try? Data(contentsOf: file),
        let event = try? JSONDecoder().decode(Event.self, from: data)
      else {
        try? FileManager.default.removeItem(at: file)
        continue
      }
      if event.source == "Hook" {
        UserDefaults.standard.set(event.date, forKey: "lastHook." + event.provider.rawValue)
      }
      board.apply(event)
      consumed.append(file)
    }
    if !consumed.isEmpty {
      do {
        guard let store else { return }
        try store.save(board)
        for file in consumed { try? FileManager.default.removeItem(at: file) }
      } catch {
        message = "Events are safely queued; storage failed: \(error.localizedDescription)"
      }
    }
  }
  private func pollCodex() {
    guard !polling else { return }
    polling = true
    let reader = codex
    let claudeReader = claude
    readerQueue.async { [weak self] in
      let events = (reader.poll() + claudeReader.poll()).sorted { $0.0.date < $1.0.date }
      let health = reader.health
      Task { @MainActor in
        guard let self else { return }
        for (event, historical) in events { self.board.apply(event, historical: historical) }
        let lastHook = UserDefaults.standard.object(forKey: "lastHook.codex") as? Date
        let hookHealth =
          lastHook.map { "Last hook: \($0.formatted(date: .abbreviated, time: .shortened))" }
          ?? (self.codexHooksInstalled ? "Hooks awaiting first event" : "Hooks not installed")
        let status = health + " · " + hookHealth
        if self.codexStatus != status { self.codexStatus = status }
        self.polling = false
      }
    }
  }
  func save() {
    do { try store?.save(board) } catch {
      message = "Could not save sessions: \(error.localizedDescription)"
    }
  }
  func open(_ id: String) {
    guard let s = board.sessions[id] else { return }
    selected = id
    guard !navigating else { return }
    navigating = true
    navigationNote = nil
    Task {
      defer { navigating = false }
      do {
        if try await Navigator.open(s) {
          board.seen(id, matching: s.alert?.id)
          recordNavigation("Exact Terminal tab confirmed", session: s)
        } else {
          navigationNote = "Codex open requested. Mark seen after checking the conversation."
          recordNavigation("Codex link accepted; destination unconfirmed", session: s)
        }
        save()
      } catch {
        message = error.localizedDescription
        recordNavigation("Switch failed: \(error.localizedDescription)", session: s)
      }
    }
  }
  private func recordNavigation(_ result: String, session: Session) {
    lastNavigationResult =
      "\(session.project) · \(result) · \(Date().formatted(date: .omitted, time: .standard))"
    UserDefaults.standard.set(lastNavigationResult, forKey: "lastNavigationResult")
  }
  func seen(_ id: String) {
    board.seen(id)
    if attention.isEmpty {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
        "session-control-attention"
      ])
    }
    save()
  }
  func snooze(_ id: String) {
    board.snooze(id, until: Date().addingTimeInterval(600))
    save()
  }
  func hide(_ id: String) {
    board.sessions[id]?.hidden = true
    save()
  }
  func nextPage() { page = (page + 1) % board.pageCount }
  func jumpToAttention() {
    if let s = attention.first {
      page = s.slot / 31
      selected = s.id
      showWindow()
    }
  }
  func showWindow() {
    windowOpener?()
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: {
      $0.identifier?.rawValue != "com.apple.SwiftUI.Settings" && $0.canBecomeMain
    })?.makeKeyAndOrderFront(nil)
  }
  private func route(_ action: KeyRouting.Action) {
    switch action {
    case .open(let id): open(id)
    case .inspect(let id):
      selected = id
      showWindow()
    case .nextPage: nextPage()
    case .attention: jumpToAttention()
    }
  }
  func configureCodex(_ install: Bool) {
    do {
      try ClaudeSetup.configure(install: install, provider: .codex)
      codexHooksInstalled = ClaudeSetup.installed(provider: .codex)
      message =
        install
        ? "Codex hooks installed. Review and trust them in Codex before they can run. Transcript observation continues while hooks await review."
        : "Cue hooks removed from Codex."
    } catch { message = error.localizedDescription }
  }
  func configureClaude(_ install: Bool) {
    do {
      try ClaudeSetup.configure(install: install)
      hooksInstalled = ClaudeSetup.installed()
      message =
        install
        ? "Claude monitoring installed. Existing sessions may need /hooks review or a restart before the new hooks run. Your other hooks were preserved."
        : "Cue hooks removed. Other Claude settings were preserved."
    } catch { message = error.localizedDescription }
  }
  func setDeck(_ enabled: Bool) {
    board.preferences.deckEnabled = enabled
    if enabled {
      deck.connect()
      deck.brightness(board.preferences.brightness)
    } else {
      deck.disconnect()
    }
    hardwareStatus = deck.status
    save()
  }
  private let notificationHelp =
    "macOS has blocked notifications. Open System Settings → Notifications → Cue and turn on Allow Notifications, then try Send test again."
  func refreshNotificationStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      Task { @MainActor in
        switch settings.authorizationStatus {
        case .notDetermined: self.notificationStatus = "Permission not requested yet"
        case .denied: self.notificationStatus = "Blocked in macOS Settings"
        case .authorized: self.notificationStatus = "Allowed"
        case .provisional: self.notificationStatus = "Allowed quietly"
        @unknown default: self.notificationStatus = "Permission unavailable"
        }
      }
    }
  }
  func authorizeNotifications() {
    Task { _ = await prepareNotifications() }
  }
  private func prepareNotifications() async -> Bool {
    let center = UNUserNotificationCenter.current()
    var settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      } catch {
        message = "Could not request notification permission: \(error.localizedDescription)"
        refreshNotificationStatus()
        return false
      }
      settings = await center.notificationSettings()
    }
    refreshNotificationStatus()
    if settings.authorizationStatus == .denied {
      message = notificationHelp
      return false
    }
    guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
      message = "Notification permission has not been granted. Try Enable notifications again."
      return false
    }
    return true
  }
  func refreshLoginStatus() {
    switch SMAppService.mainApp.status {
    case .enabled: loginStatus = "Starts at login"
    case .requiresApproval: loginStatus = "Allow login start in System Settings"
    case .notRegistered: loginStatus = "Login start disabled"
    case .notFound: loginStatus = "Install the app before enabling login start"
    @unknown default: loginStatus = "Login status unavailable"
    }
  }
  func testNotification() {
    Task {
      guard await prepareNotifications() else { return }
      let content = UNMutableNotificationContent()
      content.title = "Cue notification check"
      content.body = "This is a test of the notification channel used for session alerts."
      content.sound = .default
      do {
        try await UNUserNotificationCenter.current().add(
          UNNotificationRequest(
            identifier: "session-control-test", content: content, trigger: nil))
        message =
          "Test notification submitted. If it is hidden, check macOS notification and Focus settings."
      } catch {
        refreshNotificationStatus()
        message =
          "Notification check failed: \(error.localizedDescription). Open System Settings → Notifications → Cue to check permission."
      }
    }
  }
  func login(_ enabled: Bool) {
    defer { refreshLoginStatus() }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch { message = error.localizedDescription }
  }
  private func notify(_ ids: [String]) {
    let content = UNMutableNotificationContent()
    content.title =
      ids.count == 1
      ? (board.sessions[ids[0]]?.project ?? "Session needs you") : "\(ids.count) sessions need you"
    content.body = "Open Cue to return to the session."
    content.sound = .default
    content.userInfo = ["session": ids[0]]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "session-control-attention", content: content, trigger: nil)
    )
  }
  func shutdown() {
    timer?.invalidate()
    save()
    deck.disconnect()
    if lockFile >= 0 {
      Darwin.close(lockFile)
      lockFile = -1
    }
  }
}
