import Darwin
import SessionCore
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  static weak var model: AppModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { Self.model?.shutdown() }
  }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["session"] as? String
    Task { @MainActor in
      if let id { Self.model?.open(id) }
      completionHandler()
    }
  }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) { completionHandler([.banner, .sound]) }
}
@main struct SessionControlApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var model = AppModel()
  var body: some Scene {
    Window("Cue", id: "dashboard") {
      Dashboard(model: model).onAppear { AppDelegate.model = model }.frame(
        minWidth: 1080, minHeight: 660)
    }.defaultSize(width: 1280, height: 800)
      .commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
          Button("Connections & settings…") { model.showSettings = true }.keyboardShortcut(",")
        }
      }
    MenuBarExtra {
      Button("Open Cue") { model.showWindow() }
      Button("Next session needing attention") { model.jumpToAttention() }
      Divider()
      Toggle(
        "Quiet mode",
        isOn: Binding(
          get: { model.board.preferences.quiet },
          set: {
            model.board.preferences.quiet = $0
            model.save()
          }))
      Divider()
      Button("Quit Cue") { NSApp.terminate(nil) }
    } label: {
      Label(
        "\(model.attention.count)",
        systemImage: model.attention.isEmpty ? "square.grid.3x3" : "bell.badge")
    }
  }
}
struct Dashboard: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: AppModel
  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Cue").font(.title2.weight(.semibold))
          Text("Agent sessions, at a glance").font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 14) {
          Label("\(model.board.visible.count) sessions", systemImage: "square.grid.2x2")
          Button {
            model.jumpToAttention()
          } label: {
            Label("\(model.attention.count) need you", systemImage: "bell.badge")
          }.buttonStyle(.plain)
        }.font(.headline)
        Divider()
        Text("CONNECTIONS").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
        connection("Claude Code", detail: model.claudeHookStatus, symbol: "terminal")
        connection("Codex Desktop", detail: model.codexStatus, symbol: "macwindow")
        connection("Stream Deck XL", detail: model.hardwareStatus, symbol: "square.grid.3x3")
        Spacer()
        Toggle(
          "Quiet mode",
          isOn: Binding(
            get: { model.board.preferences.quiet },
            set: {
              model.board.preferences.quiet = $0
              model.save()
            }))
        Button {
          model.showSettings = true
        } label: {
          Label("Connections & settings", systemImage: "gearshape")
        }.controlSize(.large)
      }.padding(24).frame(width: 225)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Your sessions").font(.largeTitle.weight(.semibold))
              Text("Select to inspect. Open to return to the exact session.").foregroundStyle(
                .secondary)
            }
            Spacer()
            HStack {
              Button {
                model.page = max(0, model.page - 1)
              } label: {
                Image(systemName: "chevron.left")
              }.disabled(model.page == 0)
              Text("\(model.page+1) / \(model.board.pageCount)").monospacedDigit()
              Button {
                model.nextPage()
              } label: {
                Image(systemName: "chevron.right")
              }.disabled(model.board.pageCount == 1)
            }
          }
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8
          ) {
            ForEach(0..<32, id: \.self) { key in
              let session = key < 31 ? model.board.page(model.page)[key] : nil
              Button {
                if key == 31 {
                  model.nextPage()
                } else if let session {
                  model.selected = session.id
                }
              } label: {
                KeyCard(
                  session: session, index: key,
                  selected: session != nil && model.selected == session?.id,
                  attention: model.attention.count, page: model.page, pages: model.board.pageCount)
              }
              .buttonStyle(.plain).help(
                session.map { "\($0.project)\n\($0.task)\n\($0.path)" }
                  ?? (key == 31
                    ? "Next page; hold the physical key for attention" : "Available for a session")
              )
              .contextMenu {
                if let session {
                  Button("Open session") { model.open(session.id) }
                  Button("Mark seen") { model.seen(session.id) }
                  Button("Snooze 10 minutes") { model.snooze(session.id) }
                }
              }
            }
          }
          HStack(spacing: 16) {
            legend(.working)
            legend(.waiting)
            legend(.ready)
            legend(.failed)
          }.font(.caption)
          if let note = model.integrationNote { Text(note).font(.callout).foregroundStyle(.orange) }
          Divider()
          if let id = model.selected, let session = model.board.sessions[id] {
            Inspector(model: model, session: session).id(id)
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Label("A place for every session", systemImage: "cursorarrow.click").font(
                .title3.weight(.semibold))
              Text(
                model.board.visible.isEmpty
                  ? "Connect Claude Code in settings, then submit a prompt in a Terminal session. Recent Codex conversations appear automatically."
                  : "Select a key to see the full project name, recent prompts, and connection details."
              ).foregroundStyle(.secondary)
            }.padding(.vertical, 20)
            Spacer()
          }
        }.padding(24)
      }.frame(minWidth: 780)
    }
    .onAppear { model.windowOpener = { openWindow(id: "dashboard") } }
    .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
    .alert(
      "Cue",
      isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    ) {
      Button("OK") { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
  }
  func connection(_ title: String, detail: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
    }
  }
  func legend(_ state: SessionState) -> some View {
    Label {
      Text(state.title)
    } icon: {
      Image(systemName: state.symbol).foregroundStyle(Color(nsColor: state.color))
    }
  }
}
struct KeyCard: View {
  var session: Session?
  var index: Int
  var selected: Bool
  var attention: Int
  var page: Int
  var pages: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let s = session {
        HStack {
          Text(s.provider.badge).font(.system(size: 10, weight: .bold))
          Spacer()
          Image(systemName: s.state.symbol).foregroundStyle(Color(nsColor: s.state.color))
        }
        Text(s.project).font(.system(size: 13, weight: .semibold)).lineLimit(2).minimumScaleFactor(
          0.85)
        Text(s.task).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        Spacer(minLength: 0)
        if s.alert?.active(at: Date()) == true {
          Text("UNSEEN").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(
            Color(nsColor: s.state.color))
        }
      } else if index == 31 {
        Image(systemName: "arrow.right")
        Text("\(attention) need you").font(.system(size: 12, weight: .semibold))
        Text("Page \(page+1) / \(pages)").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        Text(String(format: "%02d", page * 31 + index + 1)).font(.caption.monospaced())
          .foregroundStyle(.tertiary)
        Spacer()
        Image(systemName: "plus").foregroundStyle(.quaternary)
        Spacer()
      }
    }.padding(10).frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
      .background(
        selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(alignment: .top) {
        if let session {
          Rectangle().fill(Color(nsColor: session.state.color)).frame(height: 3).padding(
            .horizontal, 10)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 10).stroke(
          selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
      }
      .accessibilityLabel(
        session.map { "\($0.project), \($0.task), \($0.state.title)" } ?? "Key \(index+1)")
  }
}
struct Inspector: View {
  @ObservedObject var model: AppModel
  var session: Session
  @State private var task = ""
  @State private var alias = ""
  @State private var destination = 1
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(session.project).font(.title2.weight(.semibold)).textSelection(.enabled)
        Spacer()
        Button("Snooze 10 min") { model.snooze(session.id) }
        Button("Mark seen") { model.seen(session.id) }
        Button(model.navigating ? "Opening…" : "Open session") { model.open(session.id) }
          .buttonStyle(.borderedProminent).disabled(model.navigating)
      }
      if let note = model.navigationNote { Text(note).font(.caption).foregroundStyle(.secondary) }
      Text(session.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      HStack {
        Label(session.state.title, systemImage: session.state.symbol).foregroundStyle(
          Color(nsColor: session.state.color))
        Text("· \(session.provider.title) · \(session.source)").foregroundStyle(.secondary)
      }.font(.callout)
      HStack {
        TextField("Task label", text: $task)
        TextField("Project alias (optional)", text: $alias)
        Button("Save labels") {
          model.board.sessions[session.id]?.customTitle = task
          model.board.sessions[session.id]?.projectAlias = alias
          model.save()
        }
      }
      HStack {
        Toggle(
          "Pin",
          isOn: Binding(
            get: { session.pinned },
            set: {
              model.board.sessions[session.id]?.pinned = $0
              model.save()
            }))
        Text("Key")
        Stepper(value: $destination, in: 1...992) { Text("\(destination)").monospacedDigit() }
          .frame(width: 120)
        Button("Move") {
          model.board.move(session.id, to: destination - 1)
          model.page = (destination - 1) / 31
          model.save()
        }
        Spacer()
        Button("Remove from board") { model.hide(session.id) }
      }.font(.caption)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(session.prompts.reversed()) { prompt in
            VStack(alignment: .leading, spacing: 4) {
              Text(prompt.date, style: .time).font(.caption).foregroundStyle(.secondary)
              Text(prompt.text).font(.system(size: 14)).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            }
            Divider()
          }
          if session.prompts.isEmpty { Text("No prompt captured yet.").foregroundStyle(.secondary) }
        }
      }.frame(height: 160)
    }.onAppear {
      task = session.task
      alias = session.projectAlias ?? ""
      destination = session.slot + 1
    }
  }
}
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Connections & settings").font(.title2.weight(.semibold))
        GroupBox("Claude Code in Terminal") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Install the bundled reporter into Claude’s hooks. Other hooks are preserved, and a backup is saved before changes."
            )
            HStack {
              Button(model.hooksInstalled ? "Repair monitoring" : "Connect Claude Code") {
                model.configureClaude(true)
              }
              if model.hooksInstalled {
                Button("Remove monitoring") { model.configureClaude(false) }
              }
            }
          }.padding(8)
        }
        GroupBox("Codex Desktop") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Recent conversations are observed automatically. Hooks add permission and tool events after you review and trust them in Codex."
            )
            HStack {
              Button(model.codexHooksInstalled ? "Repair Codex hooks" : "Install Codex hooks") {
                model.configureCodex(true)
              }
              if model.codexHooksInstalled {
                Button("Remove hooks") { model.configureCodex(false) }
              }
            }
          }.padding(8)
        }
        GroupBox("Stream Deck XL") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Quit Elgato’s Stream Deck app or any other device controller before connecting. The app uses 31 session keys and one page/attention key."
            )
            Toggle(
              "Connect to Stream Deck XL",
              isOn: Binding(
                get: { model.board.preferences.deckEnabled }, set: { model.setDeck($0) }))
            HStack {
              Text("Brightness")
              Slider(
                value: Binding(
                  get: { Double(model.board.preferences.brightness) },
                  set: {
                    model.board.preferences.brightness = Int($0)
                    model.deck.brightness(Int($0))
                    model.save()
                  }), in: 0...100)
              Text("\(model.board.preferences.brightness)%")
            }
          }.padding(8)
        }
        GroupBox("Connection checks") {
          VStack(alignment: .leading, spacing: 8) {
            Label(model.claudeHookStatus, systemImage: "terminal")
            Label(model.codexStatus, systemImage: "macwindow")
            Text(model.lastPhysicalKey)
            Text(model.lastNavigationResult)
            Text(
              "Press a session key to check its destination. An accepted Codex link still needs your confirmation."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        GroupBox("Attention") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Key pulse → stronger pulse after 1 min → notification after 3 min → spare keys after 5 min → reminders after 10 min. Ready sessions receive a gentler reminder."
            )
            Toggle(
              "Quiet mode",
              isOn: Binding(
                get: { model.board.preferences.quiet },
                set: {
                  model.board.preferences.quiet = $0
                  model.save()
                }))
            Toggle(
              "Reduce motion",
              isOn: Binding(
                get: { model.board.preferences.reducedMotion },
                set: {
                  model.board.preferences.reducedMotion = $0
                  model.save()
                }))
            HStack {
              Button("Enable notifications") { model.authorizeNotifications() }
              Button("Send test") { model.testNotification() }
              Text(model.notificationStatus).foregroundStyle(.secondary)
            }
          }.padding(8)
        }
        Text(model.loginStatus).font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("Start at login") { model.login(true) }
          Button("Disable login start") { model.login(false) }
          Spacer()
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        if let message = model.message {
          Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }.padding(24)
    }.frame(width: 610, height: 680)
  }
}
