import AppKit
import IPRecordCore
import ServiceManagement
import SwiftUI

@MainActor final class AppModel: ObservableObject {
  @Published var state = EngineState()
  @Published var hasStarted = false
  var showWelcome: () -> Void = {}
  var retryStartup: (() -> Void)?
  var displayTitle: String { hasStarted || state.storageError != nil ? state.title : "等待开始" }
  @Published var databaseHealth: [Family: String] = [:]
  @Published var loginDescription = "正在读取系统状态"
  @Published var loginError: String?
  @Published var interval: Int
  @Published var actionError: String?
  @Published var exportMessage: String?
  @Published var exportRunning = false
  @Published var exportDone = 0
  @Published var exportTotal = 0
  let defaults: UserDefaults
  let directory: URL
  let geo: GeoResolver
  let store: HistoryStore
  let reader: HistoryReader
  var exportTask: Task<Void, Never>?
  var showHistory: () -> Void = {}
  var showSettings: () -> Void = {}
  var quit: () -> Void = {}
  lazy var engine: RecordingEngine = RecordingEngine(
    store: store, geo: geo, interval: TimeInterval(interval),
    update: { [weak self] value in
      Task { @MainActor in if let self, value.revision >= self.state.revision { self.state = value }
      }
    })
  init(directory: URL, defaults: UserDefaults = .standard) {
    self.directory = directory
    self.defaults = defaults
    interval =
      [300, 900, 1800].contains(defaults.integer(forKey: "checkInterval"))
      ? defaults.integer(forKey: "checkInterval") : 300
    let url = directory.appendingPathComponent("history.sqlite")
    store = HistoryStore(url: url)
    reader = HistoryReader(url: url)
    geo = GeoResolver(directory: Bundle.main.resourceURL!.appendingPathComponent("ip2region"))
    state.paused = defaults.bool(forKey: "paused")
    refreshLogin()
  }
  var manualLogin: Bool { defaults.bool(forKey: "manualLogin") }
  var loginEnabled: Bool { !manualLogin && SMAppService.mainApp.status == .enabled }
  func start() {
    hasStarted = true
    Task {
      await engine.start(paused: defaults.bool(forKey: "paused"))
      databaseHealth = await geo.databaseHealth()
    }
  }
  func beginFirstRun(login: Bool) {
    defaults.set(true, forKey: "onboarded")
    setLogin(login)
    start()
  }
  func refreshLogin() {
    if manualLogin {
      loginDescription = "由系统设置管理（应用无法读取手工项状态）"
      return
    }
    switch SMAppService.mainApp.status {
    case .enabled: loginDescription = "已启用"
    case .requiresApproval: loginDescription = "需要在系统设置中允许"
    case .notRegistered: loginDescription = "未启用"
    case .notFound: loginDescription = "不可用"
    @unknown default: loginDescription = "系统状态未知"
    }
  }
  func setLogin(_ enabled: Bool) {
    guard !manualLogin else { return }
    loginError = nil
    do {
      if enabled && SMAppService.mainApp.status != .enabled
        && SMAppService.mainApp.status != .requiresApproval
      {
        try SMAppService.mainApp.register()
      } else if !enabled && SMAppService.mainApp.status != .notRegistered {
        try SMAppService.mainApp.unregister()
      }
    } catch { loginError = "登录启动设置失败：\(error.localizedDescription)" }
    refreshLogin()
  }
  func useSystemLogin() {
    // Avoid leaving both managed and manual registration enabled.
    do {
      if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
      {
        try SMAppService.mainApp.unregister()
      }
      defaults.set(true, forKey: "manualLogin")
      loginError = nil
    } catch { loginError = error.localizedDescription }
    refreshLogin()
  }
  func useAppLogin() {
    defaults.set(false, forKey: "manualLogin")
    refreshLogin()
  }
  func togglePause() {
    guard hasStarted else { return }
    let paused = !state.paused
    defaults.set(paused, forKey: "paused")
    // Invalidate callbacks synchronously before the actor receives the control change.
    engine.epoch.bump()
    Task { if paused { await engine.pause() } else { await engine.resume() } }
  }
  func changeInterval(_ value: Int) {
    interval = value
    defaults.set(value, forKey: "checkInterval")
    Task { await engine.setInterval(TimeInterval(value)) }
  }
  func retryStorage() {
    if let retryStartup { retryStartup() } else { Task { await engine.retryStorage() } }
  }
  func checkNow() { Task { await engine.checkNow() } }
  func clearHistory() {
    let alert = NSAlert()
    alert.messageText = "清空全部历史？"
    alert.informativeText = "保留当前状态、设置和归属数据库。下次网络状态变化或记录空档起点开始新增历史。此操作无法撤销。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "清空历史")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    Task {
      do {
        try await engine.clearHistory()
        defaults.set(true, forKey: "historyCleared")
        NotificationCenter.default.post(name: .historyChanged, object: nil)
      } catch { actionError = "清空失败：\(error.localizedDescription)" }
    }
  }
  func export(format: String, filter: HistoryFilter) {
    guard !exportRunning else { return }
    exportRunning = true
    exportDone = 0
    exportTotal = 0
    exportMessage = nil
    Task {
      do {
        let count = try await reader.count(filter: filter)
        guard exportRunning else { return }
        let panel = NSSavePanel()
        panel.title = "导出 \(count) 条历史"
        panel.message = "所选范围包含 \(count) 条记录。文件可能包含公网地址及本机网络配置，请妥善保存。"
        let filenameDate = DateFormatter()
        filenameDate.locale = Locale(identifier: "en_US_POSIX")
        filenameDate.dateFormat = "yyyy-MM-dd"
        filenameDate.timeZone = .current
        panel.nameFieldStringValue = "IP Record-\(filenameDate.string(from:Date())).\(format)"
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
          if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent) { response in
              continuation.resume(returning: response)
            }
          } else {
            panel.begin { response in continuation.resume(returning: response) }
          }
        }
        guard response == .OK, let destination = panel.url else {
          exportRunning = false
          return
        }
        exportTask = Task {
          do {
            let written = try await reader.export(
              to: destination, format: format, filter: filter,
              progress: { [weak self] done, total in
                Task { @MainActor in
                  self?.exportDone = done
                  self?.exportTotal = total
                }
              })
            exportMessage = "已导出 \(written) 条记录"
          } catch is CancellationError { exportMessage = "导出已取消" } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
          }
          exportRunning = false
          exportTask = nil
        }
      } catch {
        exportRunning = false
        exportMessage = "无法读取导出范围：\(error.localizedDescription)"
      }
    }
  }
  func cancelExport() { exportTask?.cancel() }
  func diskUsage() -> String {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    let size = files.reduce(0) {
      $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }
}
extension Notification.Name {
  static let historyChanged = Notification.Name("IPRecordHistoryChanged")
}

func displayTime(_ date: Date?) -> String {
  guard let date else { return "未确认" }
  let f = DateFormatter()
  f.locale = Locale(identifier: "zh_CN")
  f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
  return f.string(from: date)
}
func fullTime(_ date: Date?) -> String {
  guard let date else { return "未确认" }
  let f = DateFormatter()
  f.locale = Locale(identifier: "zh_CN")
  f.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
  return f.string(from: date)
}
func probeStatus(_ p: ProbeResult) -> String {
  switch p.status {
  case "confirmed": "已获取"
  case "failed": p.family == .v6 ? "IPv6 出口未确认" : "公网 IPv4 查询失败"
  case "skippedNoPath": "网络不可用，暂未检查公网出口"
  case "deferredCooldown": "等待确认新网络出口"
  default: "暂未确认出口"
  }
}
func errorText(_ code: String?) -> String {
  guard let code else { return "" }
  return [
    "timeout": "查询超时", "dns": "域名解析失败", "connection": "连接失败", "tls": "安全连接失败", "http": "服务返回错误",
    "authentication": "需要网络或代理认证", "oversized": "服务响应过长", "invalidAddress": "服务返回了无效地址",
    "familyMismatch": "服务返回地址族不符", "redirect": "服务重定向已拒绝", "cachedResponse": "缓存响应未用于更新确认",
    "cancelled": "检查已取消",
  ][code] ?? code
}
