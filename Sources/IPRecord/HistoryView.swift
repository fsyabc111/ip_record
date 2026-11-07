import IPRecordCore
import SwiftUI

@MainActor final class HistoryViewModel: ObservableObject {
  @Published var rows: [HistoryRecord] = []
  @Published var selected: Int64?
  @Published var previous: HistoryRecord?
  @Published var loading = false
  @Published var error: String?
  @Published var hasMore = false
  @Published var total = 0
  var filter = HistoryFilter()
  private var generation = 0
  private var loadTask: Task<Void, Never>?
  let reader: HistoryReader
  init(reader: HistoryReader) { self.reader = reader }
  func load(_ filter: HistoryFilter, more: Bool = false) {
    loadTask?.cancel()
    generation += 1
    let version = generation
    self.filter = filter
    loading = true
    error = nil
    let cursor = more ? rows.last?.id : nil
    loadTask = Task {
      do {
        if !more { try await Task.sleep(for: .milliseconds(180)) }
        let page = try await reader.page(filter: filter, before: cursor)
        let count = try await reader.count(filter: filter)
        guard !Task.isCancelled, version == generation else { return }
        if more {
          rows += page
        } else {
          rows = page
          selected = nil
          previous = nil
        }
        total = count
        hasMore = page.count == 100
        loading = false
      } catch is CancellationError {} catch {
        guard version == generation else { return }
        self.error = error.localizedDescription
        loading = false
      }
    }
  }
  func select(_ id: Int64?) {
    selected = id
    previous = nil
    if let id {
      Task {
        let result = try? await reader.previousState(before: id)
        if selected == id { previous = result }
      }
    }
  }
}
struct HistoryView: View {
  @ObservedObject var model: AppModel
  @StateObject private var history: HistoryViewModel
  @ViewState private var range = "7"
  @ViewState private var category = "all"
  @ViewState private var search = ""
  @ViewState private var customStart = Calendar.current.startOfDay(for: Date())
  @ViewState private var customEnd = Date()
  @ViewState private var exportAll = false
  init(model: AppModel) {
    self.model = model
    _history = StateObject(wrappedValue: HistoryViewModel(reader: model.reader))
  }
  private var filter: HistoryFilter {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let start: Date? =
      range == "all"
      ? nil
      : (range == "custom"
        ? calendar.startOfDay(for: customStart)
        : calendar.date(
          byAdding: .day, value: range == "today" ? 0 : -(Int(range) ?? 7) + 1, to: today))
    let end =
      range == "custom"
      ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))?
        .addingTimeInterval(-0.001) : nil
    return .init(since: start, until: end, category: category, search: search)
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("范围", selection: $range) {
          Text("今天").tag("today")
          Text("最近 7 天").tag("7")
          Text("最近 30 天").tag("30")
          Text("全部时间").tag("all")
          Text("自定义日期").tag("custom")
        }.frame(width: 170)
        Picker("类型", selection: $category) {
          Text("全部类型").tag("all")
          Text("变化记录（隐藏空档）").tag("state")
          Text("记录空档").tag("gaps")
          ForEach(["公网地址", "本机地址", "连接状态", "DNS", "网关", "代理", "查询状态"], id: \.self) {
            Text($0).tag($0)
          }
        }.frame(width: 190)
        TextField("搜索 IP、地区、接口…", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel(
          "搜索历史")
        Button("刷新") { history.load(filter) }.disabled(history.loading)
        Menu("导出…") {
          Toggle("导出全部历史", isOn: $exportAll)
          Text(exportAll ? "全部历史" : "当前筛选 · \(history.total) 条")
          Button("CSV 摘要") { model.export(format: "csv", filter: exportAll ? .init() : filter) }
          Button("JSON 完整数据") { model.export(format: "json", filter: exportAll ? .init() : filter) }
        }.disabled(model.exportRunning)
      }.padding()
      if range == "custom" {
        HStack {
          DatePicker("开始", selection: $customStart, displayedComponents: .date)
          DatePicker("结束", selection: $customEnd, in: customStart..., displayedComponents: .date)
        }.padding(.horizontal).padding(.bottom, 10)
      }
      Divider()
      if let error = history.error {
        ContentUnavailableView {
          Label("无法读取历史", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试") { history.load(filter) }
        }
      } else if history.rows.isEmpty && !history.loading {
        ContentUnavailableView {
          Label(
            history.total == 0 && category == "all" && search.isEmpty
              && model.defaults.bool(forKey: "historyCleared") ? "历史已清空" : "暂无符合条件的记录",
            systemImage: "clock")
        } description: {
          Text("历史只在地址、网络状态或记录空档变化时新增。可调整时间范围或筛选条件。")
        }
      } else {
        HSplitView {
          VStack(spacing: 0) {
            Table(
              history.rows,
              selection: Binding(get: { history.selected }, set: { history.select($0) })
            ) {
              TableColumn("首次观测") { row in
                Text(displayTime(row.observedAt)).help(fullTime(row.observedAt))
              }.width(min: 140, ideal: 150)
              TableColumn("变化类型") { row in Text(row.title).font(.callout) }.width(
                min: 100, ideal: 130)
              TableColumn("公网 IPv4") { row in
                Text(row.firstObservation?.v4.address?.text ?? "—").font(
                  .system(.caption, design: .monospaced))
              }.width(min: 115, ideal: 120)
              TableColumn("归属地") { row in
                Text(row.firstObservation?.v4.geo?.location ?? "—").font(.caption)
              }.width(min: 100, ideal: 150)
            }.frame(minWidth: 500)
            HStack {
              Text("已显示 \(history.rows.count) / \(history.total) 条").font(.caption).foregroundStyle(
                .secondary)
              Spacer()
              if history.hasMore {
                Button("加载更多") { history.load(filter, more: true) }.disabled(history.loading)
              }
              if history.loading { ProgressView().controlSize(.small) }
            }.padding(10)
          }
          ScrollView {
            if let row = history.rows.first(where: { $0.id == history.selected }) {
              HistoryDetail(record: row, previous: history.previous).padding()
            } else {
              ContentUnavailableView(
                "选择一条记录", systemImage: "sidebar.right", description: Text("查看完整地址、配置和各族确认时间")
              ).frame(minHeight: 300)
            }
          }.frame(minWidth: 290, idealWidth: 350)
        }
      }
      if model.exportRunning || model.exportMessage != nil {
        Divider()
        HStack {
          if model.exportRunning {
            ProgressView(value: Double(model.exportDone), total: Double(max(model.exportTotal, 1)))
              .frame(width: 160)
            Text("正在导出 \(model.exportDone) / \(model.exportTotal)").font(.caption)
            Button("取消", action: model.cancelExport)
          } else {
            Text(model.exportMessage ?? "").font(.caption)
          }
          Spacer()
        }.padding(10)
      }
    }.frame(minWidth: 820, minHeight: 480)
      .onAppear { history.load(filter) }
      .onChange(of: filter) { _, value in history.load(value) }
      .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in
        history.load(filter)
      }
      .onChange(of: model.state.saved?.savedAt) { _, _ in
        if history.selected == nil && history.rows.count <= 100 { history.load(filter) }
      }
  }
}
struct HistoryDetail: View {
  let record: HistoryRecord
  let previous: HistoryRecord?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(record.title).font(.title3.bold())
      Text("记录 #\(record.id) · \(fullTime(record.observedAt))").font(.caption).foregroundStyle(
        .secondary
      ).textSelection(.enabled)
      if let o = record.firstObservation {
        PublicAddressView(
          probe: o.v4, fresh: true, checking: false, family: .v4, history: true,
          summaryConfirmedAt: record.confirmationSummary.lastConfirmedV4At)
        Divider()
        PublicAddressView(
          probe: o.v6, fresh: true, checking: false, family: .v6, history: true,
          summaryConfirmedAt: record.confirmationSummary.lastConfirmedV6At)
        Divider()
        DisclosureGroup("全部本机地址 · \(o.network.addresses.count) 个") {
          ForEach(o.network.addresses) { LocalAddressRow(address: $0) }
        }
        DisclosureGroup("系统网络配置") { ConfigurationView(network: o.network) }
        if let old = previous?.firstObservation {
          DisclosureGroup("与上一条相比") {
            let added = o.network.addresses.filter { !old.network.addresses.contains($0) }
            let removed = old.network.addresses.filter { !o.network.addresses.contains($0) }
            ForEach(added) {
              Text("新增：\($0.interface) \($0.ip.text)").font(.caption).textSelection(.enabled)
            }
            ForEach(removed) {
              Text("移除：\($0.interface) \($0.ip.text)").font(.caption).textSelection(.enabled)
            }
            Text(o.changes(from: old).joined(separator: "、")).font(.caption)
          }
        }
        DisclosureGroup("观测与归属详情") {
          VStack(alignment: .leading, spacing: 6) {
            Text("首次采集：\(fullTime(o.startedAt)) — \(fullTime(o.completedAt))")
            Text("最近检查：\(fullTime(record.confirmationSummary.lastCheckedAt))")
            Text("快照：\(o.consistency == "stable" ? "读取窗口稳定" : "网络变化中，不稳定")")
            Text("触发原因：\(o.triggers.joined(separator:", "))")
            Text("观测时区 offset：\(record.timezoneOffset) 秒")
            Text("上下文：\(o.contextID)\nSession：\(record.sessionID)")
            if let closed = record.confirmationSummary.closedAt {
              Text("观测关闭：\(fullTime(closed)) · \(record.confirmationSummary.closeReason ?? "")")
            }
            ForEach([Family.v4, .v6], id: \.rawValue) { f in
              let geo = f == .v4 ? o.v4.geo : o.v6.geo
              Text("\(f.label) 归属库：ip2region v3.18.0\nSHA-256：\(geo?.databaseHash ?? "未查询")")
              Text(
                "国家：\(geo?.country ?? "数据库未提供")\n省／地区：\(geo?.province ?? "数据库未提供")\n城市：\(geo?.city ?? "数据库未提供")\n组织：\(geo?.isp ?? "数据库未提供")"
              )
            }
          }.font(.caption).textSelection(.enabled).padding(.top, 6)
        }
      } else {
        Text("记录空档标记，不包含当时成功确认的公网地址。").foregroundStyle(.secondary)
        if let id = record.previousStateRecordID { Text("先前状态记录：#\(id)").font(.caption) }
        if record.kind == "uncleanGap" {
          Text("上次进程未正常结束，无法确定中断的精确时间。").font(.caption).foregroundStyle(.secondary)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
