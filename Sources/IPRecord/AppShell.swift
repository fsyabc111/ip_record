import AppKit
import Darwin
import IPRecordCore
import SwiftUI

enum InstanceLockError: Error { case alreadyRunning }
final class DataDirectoryLock {
  private let fd: Int32
  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    fd = Darwin.open(
      directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw RecordError.message("无法访问记录目录") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(fd)
      throw InstanceLockError.alreadyRunning
    }
  }
  deinit {
    flock(fd, LOCK_UN)
    Darwin.close(fd)
  }
}
@MainActor
final class AppShell: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
  private var dataLock: DataDirectoryLock?
  private(set) var model: AppModel!
  private var statusItem: NSStatusItem!
  private var popover: NSPopover?
  private var historyWindow: NSWindow?
  private var settingsWindow: NSWindow?
  private var welcomeWindow: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var activationObserver: NSObjectProtocol?
  private var observationTask: Task<Void, Never>?
  private var terminating = false
  private var validationDirectory: URL?
  private var resourceValidation = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    umask(0o077)
    NSApp.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--self-check"), args.indices.contains(index + 1) {
      validationDirectory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }
    if let index = args.firstIndex(of: "--record-validation"), args.indices.contains(index + 1) {
      validationDirectory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
      resourceValidation = true
    }
    let directory =
      validationDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("local.fsy.iprecord", isDirectory: true)
    var startupError: String?
    do { dataLock = try DataDirectoryLock(directory: directory) } catch InstanceLockError
      .alreadyRunning
    {
      NSApp.terminate(nil)
      return
    } catch { startupError = error.localizedDescription }
    model = AppModel(
      directory: directory,
      defaults: validationDirectory == nil
        ? .standard
        : UserDefaults(
          suiteName: "local.fsy.iprecord.validation." + String(digest(directory.path).prefix(16)))!)
    model.showWelcome = { [weak self] in self?.showWelcome() }
    model.showHistory = { [weak self] in self?.showHistory() }
    model.showSettings = { [weak self] in self?.showSettings() }
    model.quit = { DispatchQueue.main.async { NSApp.terminate(nil) } }
    configureMainMenu()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePopover)
    updateIcon()
    observationTask = Task { [weak self] in
      guard let self else { return }
      for await value in self.model.$state.values {
        self.updateIcon()
        if self.resourceValidation, let dir = self.validationDirectory {
          let counters = [
            "rounds": value.rounds, "requests": value.requests,
            "storageBlocked": value.storageError == nil ? 0 : 1,
          ]
          try? jsonEncoder().encode(counters).write(
            to: dir.appendingPathComponent("counters.json"), options: .atomic)
        }
      }
    }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.model.refreshLogin() } }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.model.engine.epoch.bump()
          Task { await self.model.engine.sleep() }
        }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.model.engine.epoch.bump()
          Task { await self.model.engine.wake() }
        }
      })
    observers.append(
      center.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.model.refreshLogin() } })
    if let startupError {
      model.state.storageError = startupError
      model.retryStartup = { [weak self] in
        guard let self else { return }
        do {
          self.dataLock = try DataDirectoryLock(directory: directory)
          self.model.retryStartup = nil
          self.model.start()
        } catch { self.model.state.storageError = error.localizedDescription }
      }
      updateIcon()
    } else if validationDirectory != nil {
      model.start()
      if resourceValidation {
        Task {
          try? await Task.sleep(for: .seconds(1800))
          DispatchQueue.main.async { NSApp.terminate(nil) }
        }
      } else {
        Task { await runShellValidation() }
      }
    } else if model.defaults.bool(forKey: "onboarded") || isLoginLaunch {
      model.start()
    } else {
      showWelcome()
    }
  }
  private var isLoginLaunch: Bool {
    let event = NSAppleEventManager.shared().currentAppleEvent
    return event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
      || event?.attributeDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
  }
  private func configureMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "IP Record")
    main.addItem(appItem)
    appItem.submenu = appMenu
    let settings = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(settings)
    let history = NSMenuItem(title: "查看历史…", action: #selector(historyAction), keyEquivalent: "l")
    history.target = self
    appMenu.addItem(history)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "退出 IP Record", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let file = NSMenuItem()
    let fileMenu = NSMenu(title: "文件")
    main.addItem(file)
    file.submenu = fileMenu
    fileMenu.addItem(
      withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let edit = NSMenuItem()
    let editMenu = NSMenu(title: "编辑")
    main.addItem(edit)
    edit.submenu = editMenu
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    NSApp.mainMenu = main
  }
  private func updateIcon() {
    guard statusItem != nil, model != nil else { return }
    let state = model.state
    let name =
      state.storageError != nil
      ? "exclamationmark.triangle" : (state.paused ? "pause.circle" : "network")
    if statusItem.button?.image?.name() != NSImage.Name(name) {
      let image = NSImage(
        systemSymbolName: name, accessibilityDescription: "IP Record · " + model.displayTitle)
      image?.isTemplate = true
      image?.setName(name)
      statusItem.button?.image = image
    }
    statusItem.button?.toolTip = "IP Record · " + model.displayTitle
    statusItem.button?.setAccessibilityLabel("IP Record · " + model.displayTitle)
  }
  @objc private func togglePopover() {
    if let popover, popover.isShown {
      popover.performClose(nil)
      return
    }
    guard let button = statusItem.button else { return }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    let height = max(
      220,
      min(
        600, Int((button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 60))
    popover.contentViewController = NSHostingController(
      rootView: CurrentView(model: model, height: CGFloat(height)))
    popover.contentSize = NSSize(width: 392, height: height)
    self.popover = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }
  func popoverDidClose(_ notification: Notification) {
    popover?.contentViewController = nil
    popover = nil
  }
  private func makeWindow(title: String, size: NSSize, minimum: NSSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = title
    window.minSize = minimum
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    return window
  }
  @objc private func historyAction() { showHistory() }
  @objc private func settingsAction() { showSettings() }
  func showHistory() {
    popover?.performClose(nil)
    if historyWindow == nil {
      historyWindow = makeWindow(
        title: "IP Record · 历史", size: NSSize(width: 1040, height: 680),
        minimum: NSSize(width: 820, height: 480))
    }
    if !(historyWindow?.contentView is NSHostingView<HistoryView>), let window = historyWindow {
      let host = NSHostingView(rootView: HistoryView(model: model))
      host.sizingOptions = [.minSize]
      host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
      window.contentView = host
    }
    historyWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func showSettings() {
    popover?.performClose(nil)
    model.refreshLogin()
    if settingsWindow == nil {
      settingsWindow = makeWindow(
        title: "IP Record · 设置", size: NSSize(width: 580, height: 720),
        minimum: NSSize(width: 540, height: 600))
    }
    if !(settingsWindow?.contentView is NSHostingView<SettingsView>) {
      let host = NSHostingView(rootView: SettingsView(model: model))
      host.sizingOptions = [.minSize]
      host.frame = NSRect(origin: .zero, size: settingsWindow!.contentLayoutRect.size)
      settingsWindow?.contentView = host
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  private func showWelcome() {
    if welcomeWindow == nil {
      welcomeWindow = makeWindow(
        title: "欢迎使用 IP Record", size: NSSize(width: 470, height: 420),
        minimum: NSSize(width: 470, height: 420))
    }
    welcomeWindow?.contentView = NSHostingView(
      rootView: WelcomeView { [weak self] login in
        self?.welcomeWindow?.close()
        self?.model.beginFirstRun(login: login)
      })
    welcomeWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Keep one reusable NSWindow, release its SwiftUI tree while closed.
    if window === historyWindow || window === settingsWindow || window === welcomeWindow {
      window.contentView = nil
    }
    if window === welcomeWindow { welcomeWindow = nil }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !model.defaults.bool(forKey: "onboarded") && validationDirectory == nil {
      showWelcome()
    } else {
      if popover?.isShown != true { togglePopover() }
    }
    return false
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model != nil else { return .terminateNow }
    guard !terminating else { return .terminateLater }
    terminating = true
    popover?.performClose(nil)
    model.cancelExport()
    model.engine.epoch.bump()
    let engine = model.engine
    Task.detached {
      await engine.stop()
      // AppKit waits in a nested run loop for terminateLater. A main-queue Task
      // can be blocked by the original callback; deliver the reply as a run-loop block.
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) {
    observationTask?.cancel()
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
  }
  private func capture(_ view: NSView?, to url: URL) {
    guard let view else { return }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: image)
    try? image.representation(using: .png, properties: [:])?.write(to: url)
  }
  private func runShellValidation() async {
    guard let directory = validationDirectory else { return }
    // Programmatic integration evidence, not mouse/keyboard or user acceptance.
    for _ in 0..<160 {
      if model.state.rounds > 0 || model.state.storageError != nil || model.state.paused { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    showHistory()
    try? await Task.sleep(for: .milliseconds(500))
    capture(historyWindow?.contentView, to: directory.appendingPathComponent("history.png"))
    let first = historyWindow
    showHistory()
    let reusedHistory = historyWindow === first
    showSettings()
    try? await Task.sleep(for: .milliseconds(500))
    capture(settingsWindow?.contentView, to: directory.appendingPathComponent("settings.png"))
    let settings = settingsWindow
    showSettings()
    let reusedSettings = settingsWindow === settings
    let renderer = ImageRenderer(
      content: CurrentView(model: model).environment(\.colorScheme, .light).background(
        Color(nsColor: .windowBackgroundColor)))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    {
      try? bitmap.representation(using: .png, properties: [:])?.write(
        to: directory.appendingPathComponent("current.png"))
    }
    if CommandLine.arguments.contains("--hold-ui") { try? await Task.sleep(for: .seconds(180)) }
    historyWindow?.close()
    settingsWindow?.close()
    if CommandLine.arguments.contains("--pause-at-end") {
      model.togglePause()
      for _ in 0..<50 {
        if model.state.paused { break }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    if CommandLine.arguments.contains("--resume-at-end"), model.state.paused {
      model.togglePause()
      for _ in 0..<50 {
        if !model.state.paused { break }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    let report: [String: String] = [
      "bundle": Bundle.main.bundleIdentifier ?? "", "history_reused": "\(reusedHistory)",
      "settings_reused": "\(reusedSettings)",
      "window_close_keeps_engine": "\(!model.state.stopping)",
      "status_item": "\(statusItem != nil)",
      "dock_policy_accessory": "\(NSApp.activationPolicy() == .accessory)",
      "saved_rounds": "\(model.state.rounds)",
      "paused": "\(model.state.paused)", "public_requests": "\(model.state.requests)",
      "v4_status": model.state.saved?.observation.v4.status ?? "none",
      "v6_status": model.state.saved?.observation.v6.status ?? "none",
      "storage_error": model.state.storageError ?? "none",
    ]
    try? jsonEncoder().encode(report).write(
      to: directory.appendingPathComponent("shell-validation.json"), options: .atomic)
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }
}
