import AppKit
import IPRecordCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Form {
      Section("通用") {
        if model.manualLogin {
          Text(model.loginDescription).font(.callout)
          Text("在系统设置 → 通用 → 登录项与扩展 → 登录时打开，添加 ~/Applications/IP Record.app。应用不判定手工项是否存在。").font(
            .caption
          ).foregroundStyle(.secondary)
          Button("返回应用管理") { model.useAppLogin() }
        } else {
          Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
          Text(model.loginDescription).font(.caption).foregroundStyle(.secondary)
          if let error = model.loginError { Text(error).font(.caption).foregroundStyle(.red) }
          Button("改由系统设置手工管理") { model.useSystemLogin() }
        }
        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
      }
      Section("记录与数据") {
        Picker("检查间隔", selection: Binding(get: { model.interval }, set: model.changeInterval)) {
          Text("5 分钟（默认）").tag(300)
          Text("15 分钟").tag(900)
          Text("30 分钟").tag(1800)
        }
        Text("网络和配置变化、唤醒时补查。暂停在退出和登录后保留；关闭窗口继续记录。").font(.caption).foregroundStyle(.secondary)
        Button(model.state.paused ? "恢复记录" : "暂停记录", action: model.togglePause)
        Text("历史长期保存 · 当前占用 \(model.diskUsage())").font(.callout)
        Text(model.directory.path).font(.caption).textSelection(.enabled)
        HStack {
          Button("在 Finder 中显示") { NSWorkspace.shared.open(model.directory) }
          Button("查看历史…", action: model.showHistory)
        }
        HStack {
          Button("导出全部 CSV…") { model.export(format: "csv", filter: .init()) }
          Button("导出全部 JSON…") { model.export(format: "json", filter: .init()) }
        }.disabled(model.exportRunning)
        if model.exportRunning {
          HStack {
            ProgressView().controlSize(.small)
            Text("正在导出 \(model.exportDone) / \(model.exportTotal)")
            Button("取消", action: model.cancelExport)
          }
        }
        if let message = model.exportMessage {
          Text(message).font(.caption).textSelection(.enabled)
        }
        Button("清空历史…", role: .destructive, action: model.clearHistory)
        if let error = model.actionError { Text(error).foregroundStyle(.red).font(.caption) }
        if let error = model.state.storageError {
          Text("无法保存记录：\(error)").foregroundStyle(.red).font(.caption)
          Button("重试本地存储", action: model.retryStorage)
        }
      }
      Section("归属数据库") {
        Text("ip2region · v3.18.0 · 全球 IPv4 / IPv6")
        ForEach(DatabaseIdentity.bundled, id: \.family.rawValue) { identity in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(identity.family.label) · \(model.databaseHealth[identity.family] ?? "等待校验")")
            Text("生成时间：\(identity.generated)\nSHA-256：\(identity.hash)").font(.caption2)
              .foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Text("归属地为估计，可能缺失或过时；代理出口所在地不代表设备位置。第一版数据库随应用更新。").font(.caption).foregroundStyle(
          .secondary)
        Button("查看许可证") {
          if let url = Bundle.main.resourceURL?.appendingPathComponent("ip2region/LICENSE.md") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      Section("关于") {
        Text("IP Record 1.0.0 · Apple Silicon")
        Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption)
        Text("单进程原生菜单栏应用。公网发现仅访问 ipify；归属查询、配置和历史留在本机。DNS、代理和网关只是系统配置视图。").font(.caption)
          .foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).frame(minWidth: 540, minHeight: 600)
      .onAppear { model.refreshLogin() }
  }
}
struct WelcomeView: View {
  @ViewState private var login = true
  let begin: (Bool) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "network").font(.system(size: 36)).foregroundStyle(.tint)
      Text("开始使用 IP Record").font(.title2.bold())
      Text("应用静默留在菜单栏，每约 5 分钟及网络变化时检查公网与本机地址。关闭历史或设置窗口会继续记录，明确退出才停止。")
      Text("公网查询需访问 ipify，并沿用系统网络和代理。归属地通过捆绑数据库离线估计；网络配置与长期历史保存在这台 Mac。")
      Toggle("登录时启动", isOn: $login)
      Text("随时可以暂停；暂停会在下次登录保留。没有通知、定位、抓包或云同步。").font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("开始记录") { begin(login) }.buttonStyle(.borderedProminent).keyboardShortcut(
          .defaultAction)
      }
    }.padding(28).frame(width: 470)
  }
}
