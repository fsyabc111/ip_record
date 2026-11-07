import AppKit
import IPRecordCore
import SwiftUI

// CLT 27 ships the State property wrapper but not the new SwiftUIMacros plugin.
// A type alias explicitly selects the supported property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CopyButton: View {
  let value: String
  let label: String
  var title = "复制"
  @ViewState private var copied = false
  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    } label: {
      Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
    }
    .buttonStyle(.borderless).font(.caption).accessibilityLabel(label)
  }
}
struct AddressText: View {
  let text: String
  var body: some View {
    Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(
      horizontal: false, vertical: true
    ).frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct PublicAddressView: View {
  let probe: ProbeResult?
  let fresh: Bool
  let checking: Bool
  let family: Family
  var history = false
  var interval = 300
  var summaryConfirmedAt: Date?
  var contextID = "先前观测"
  var inactiveMessage = "正在确认新网络出口"
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("公网 \(family.label)").font(.headline)
        Spacer()
        if let p = probe, p.status == "confirmed", let ip = p.address, fresh || history {
          CopyButton(value: ip.text, label: "复制公网 \(family.label) 地址")
        }
      }
      if let p = probe {
        if p.status == "confirmed", let ip = p.address, fresh || history {
          AddressText(text: ip.text)
          if let geo = p.geo {
            Text(geo.location).font(.callout)
            if let isp = geo.isp { Text(isp).font(.caption).foregroundStyle(.secondary) }
            Text("归属地为估计").font(.caption2).foregroundStyle(.secondary)
          }
          Text("最近确认：\(displayTime(summaryConfirmedAt ?? p.completedAt))").font(.caption)
            .foregroundStyle(.secondary).help(fullTime(summaryConfirmedAt ?? p.completedAt))
          if !history && Date().timeIntervalSince(p.completedAt) > Double(interval + 30) {
            Text("记录可能已过期").font(.caption).foregroundStyle(.orange)
          }
          if checking { Text("检查中…").font(.caption).foregroundStyle(.secondary) }
        } else {
          Text(!fresh && !history ? inactiveMessage : probeStatus(p)).font(.callout)
            .foregroundStyle(.secondary)
          if p.status == "failed" {
            Text(errorText(p.error) + (p.httpStatus.map { "（HTTP \($0)）" } ?? "")).font(.caption)
              .foregroundStyle(.secondary)
          }
          let known =
            p.status == "confirmed"
            ? p.address.map {
              KnownAddress(
                address: $0, confirmedAt: summaryConfirmedAt ?? p.completedAt, contextID: contextID,
                endpoint: p.endpoint, geo: p.geo)
            } : p.lastKnown
          if let known {
            DisclosureGroup("上次记录 · \(displayTime(known.confirmedAt))") {
              HStack(alignment: .top) {
                AddressText(text: known.address.text)
                CopyButton(value: known.address.text, label: "复制上次 \(family.label) 地址")
              }
              Text("仅代表先前记录，不是本轮成功确认").font(.caption2).foregroundStyle(.secondary)
              Text(known.geo?.location ?? "归属地未知").font(.caption)
              Text(known.contextID).font(.caption2).foregroundStyle(.secondary).textSelection(
                .enabled)
            }.font(.caption)
          }
        }
        if history {
          Text("来源：\(p.endpoint)\n请求：\(fullTime(p.startedAt)) — \(fullTime(p.completedAt))").font(
            .caption
          ).foregroundStyle(.secondary).textSelection(.enabled)
        }
      } else {
        Text(checking ? "正在检查…" : "尚未检查").foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct ConfigurationView: View {
  let network: NetworkSnapshot
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "路径状态：\(network.path == "satisfied" ? "系统路径可用" : (network.path == "unsatisfied" ? "系统路径不可用" : (network.path == "requiresConnection" ? "系统路径需要连接" : "系统连接状态未知")))"
      ).font(.callout)
      Text("系统路径状态不等于互联网可达性").font(.caption).foregroundStyle(.secondary)
      Text("系统报告网关").font(.headline)
      ForEach(Array(network.gateways.enumerated()), id: \.offset) { _, group in
        GroupDetails(group: group)
      }
      Text("系统 DNS 配置").font(.headline)
      ForEach(Array(network.dns.enumerated()), id: \.offset) { _, group in
        GroupDetails(group: group)
      }
      Text("系统可见配置，可能不完整（partial）").font(.caption).foregroundStyle(.secondary)
      Text("系统代理配置").font(.headline)
      GroupDetails(group: network.proxy)
      ForEach(
        [
          "HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable",
          "ProxyAutoDiscoveryEnable",
        ], id: \.self
      ) { key in
        if network.proxy.values[key] == nil {
          Text("\(fieldTitle(key))：\(network.proxy.status == .unavailable ? "读取失败" : "未提供")").font(
            .caption)
        }
      }
      Text("配置不等于每次请求的实际路径。系统报告网关不保证是任意请求的实际下一跳。").font(.caption).foregroundStyle(.secondary)
    }.textSelection(.enabled)
  }
}
func fieldTitle(_ key: String) -> String {
  [
    "Router": "网关", "Interface": "接口", "Family": "地址族", "ServerAddresses": "DNS 服务器（按配置顺序）",
    "SearchDomains": "搜索域", "SupplementalMatchDomains": "匹配域", "SupplementalMatchOrders": "匹配优先序",
    "DomainName": "域名", "HTTPEnable": "HTTP", "HTTPSEnable": "HTTPS", "SOCKSEnable": "SOCKS",
    "HTTPProxy": "HTTP 主机", "HTTPSProxy": "HTTPS 主机", "SOCKSProxy": "SOCKS 主机",
    "HTTPPort": "HTTP 端口", "HTTPSPort": "HTTPS 端口", "SOCKSPort": "SOCKS 端口",
    "ProxyAutoConfigEnable": "自动配置 PAC", "ProxyAutoDiscoveryEnable": "自动发现 WPAD",
    "PACOrigin": "PAC 来源", "ExceptionsList": "例外", "ExcludeSimpleHostnames": "排除简单主机名",
  ][key] ?? key
}
struct GroupDetails: View {
  let group: ConfigurationGroup
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(group.source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
      if group.status == .unavailable {
        Text("读取失败").font(.caption)
      } else if group.values.isEmpty || group.status == .notObserved {
        Text("系统未提供").font(.caption)
      } else {
        ForEach(group.values.keys.sorted(), id: \.self) { key in
          Text("\(fieldTitle(key))：\(group.values[key]!.joined(separator:" → "))").font(.caption)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }
    }.padding(.bottom, 4)
  }
}
struct LocalAddressRow: View {
  let address: LocalAddress
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("\(address.interface) · \(address.type)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        CopyButton(
          value: address.ip.text, label: "复制 \(address.interface) \(address.ip.family.label) 地址")
      }
      AddressText(text: address.ip.text)
      Text("\(address.ip.scopeLabel)\(address.prefix.map { " · 前缀 /\($0)" } ?? "")").font(.caption2)
        .foregroundStyle(.secondary)
    }.padding(.vertical, 4)
  }
}
struct CurrentView: View {
  @ObservedObject var model: AppModel
  var height: CGFloat = 600
  private var inactiveMessage: String {
    if model.state.paused { return "暂停前记录 · 当前未确认" }
    if model.state.sleeping { return "睡眠前记录 · 当前未确认" }
    if model.state.storageError != nil { return "上次已保存记录 · 当前未确认" }
    return "正在确认新网络出口"
  }
  private var v6Summary: String {
    guard let o = model.state.saved?.observation else {
      return model.state.checking ? "正在检查" : "尚未检查"
    }
    return model.state.currentConfirmed ? probeStatus(o.v6) : (model.state.paused ? "暂停前记录" : "待确认")
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("IP Record").font(.title3.bold())
        Spacer()
        Text(model.displayTitle).font(.caption).foregroundStyle(
          model.state.storageError == nil ? Color.secondary : Color.red)
      }.padding()
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let error = model.state.storageError {
            Label("无法保存记录", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Text("新读取结果尚未保存，已停止后续公网检查。").font(.caption)
            DisclosureGroup("错误详情") { Text(error).font(.caption).textSelection(.enabled) }
            Button("重试保存", action: model.retryStorage)
          }
          if model.state.paused {
            Text("已暂停 · 下方为暂停前记录").font(.callout).foregroundStyle(.secondary)
          }
          PublicAddressView(
            probe: model.state.saved?.observation.v4, fresh: model.state.currentConfirmed,
            checking: model.state.checking, family: .v4, interval: model.interval,
            contextID: model.state.saved?.observation.contextID ?? "先前观测",
            inactiveMessage: inactiveMessage)
          Divider()
          DisclosureGroup("公网 IPv6 · \(v6Summary)") {
            PublicAddressView(
              probe: model.state.saved?.observation.v6, fresh: model.state.currentConfirmed,
              checking: model.state.checking, family: .v6, interval: model.interval,
              contextID: model.state.saved?.observation.contextID ?? "先前观测",
              inactiveMessage: inactiveMessage
            ).padding(.top, 6)
          }
          let network = model.state.pendingNetwork ?? model.state.saved?.observation.network
          if let network {
            Divider()
            if let primary = network.preferredV4 {
              Text("本机 IPv4").font(.headline)
              LocalAddressRow(address: primary)
            } else {
              Text("未获取本机 IPv4").foregroundStyle(.secondary)
            }
            let other = network.addresses.filter { $0.id != network.preferredV4?.id }
            DisclosureGroup("其他本机地址 · \(other.count) 个") {
              ForEach(other) { LocalAddressRow(address: $0) }
              CopyButton(
                value: network.addresses.map { $0.interface + " " + $0.ip.text }.joined(
                  separator: "\n"), label: "复制全部地址", title: "复制全部地址")
            }
            DisclosureGroup("网络配置") { ConfigurationView(network: network).padding(.top, 8) }
          }
          if let saved = model.state.saved {
            Text("最近检查：\(displayTime(saved.observation.completedAt))").font(.caption)
              .foregroundStyle(.secondary).help(fullTime(saved.observation.completedAt))
            if saved.observation.consistency == "unstable" {
              Text("网络正在变化，暂未确认出口；本机配置采集窗口不稳定。").font(.caption).foregroundStyle(.orange)
            }
          }
          if let message = model.state.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
          }
        }.padding()
      }
      Divider()
      VStack(spacing: 10) {
        HStack {
          Button(model.state.checking ? "检查中…" : "立即检查", action: model.checkNow).disabled(
            !model.hasStarted || model.state.paused || model.state.sleeping
              || model.state.storageError != nil)
          Spacer()
          Button("查看历史…", action: model.showHistory)
        }
        HStack {
          if model.hasStarted {
            Button(model.state.paused ? "恢复记录" : "暂停记录", action: model.togglePause)
          } else {
            Button("开始记录…", action: model.showWelcome)
          }
          Spacer()
          Button("设置…", action: model.showSettings)
        }
        Divider()
        HStack {
          Button("退出 IP Record", action: model.quit)
          Spacer()
        }
      }.padding()
    }.frame(width: 392).frame(height: height)
  }
}
