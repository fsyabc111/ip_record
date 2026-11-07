import Darwin
import Foundation
import Network
import SystemConfiguration

public struct NetworkSnapshotter: Sendable {
  public init() {}
  public func readSnapshot(path: String) -> NetworkSnapshot {
    let store = SCDynamicStoreCreate(nil, "IP Record read" as CFString, nil, nil)
    func dictionary(_ key: String) -> [String: Any]? {
      guard let store else { return nil }
      return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }
    var types: [String: String] = [:]
    if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
      for interface in interfaces {
        guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
        let kind = SCNetworkInterfaceGetInterfaceType(interface) as String?
        types[name] =
          kind == (kSCNetworkInterfaceTypeIEEE80211 as String)
          ? "Wi-Fi" : (kind == (kSCNetworkInterfaceTypeEthernet as String) ? "以太网" : "虚拟／其他")
      }
    }
    var local: [LocalAddress] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    let addressStatus = getifaddrs(&head)
    if addressStatus == 0 {
      defer { freeifaddrs(head) }
      var cursor = head
      while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        let entry = item.pointee
        guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
          let addr = entry.ifa_addr
        else { continue }
        let family = Int32(addr.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        let name = String(cString: entry.ifa_name)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
          getnameinfo(
            addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
            NI_NUMERICHOST) == 0,
          let ip = IPAddress(
            String(
              decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
              as: UTF8.self)), ip.isDisplayable
        else { continue }
        var prefix: Int?
        if let mask = entry.ifa_netmask {
          let count = family == AF_INET ? 4 : 16
          let offset = family == AF_INET ? 4 : 8
          let raw = UnsafeRawPointer(mask).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
          prefix = Self.prefixLength(Array(UnsafeBufferPointer(start: raw, count: count)))
        }
        local.append(.init(interface: name, type: types[name] ?? "虚拟／其他", ip: ip, prefix: prefix))
      }
    }
    var gateways: [ConfigurationGroup] = []
    var dns: [ConfigurationGroup] = []
    let globals = ["IPv4", "IPv6"].map { "State:/Network/Global/" + $0 }
    var serviceIDs = Set<String>()
    var primary4: String?
    var primary6: String?
    for (index, key) in globals.enumerated() {
      let d = dictionary(key)
      if index == 0 {
        primary4 = d?["PrimaryInterface"] as? String
      } else {
        primary6 = d?["PrimaryInterface"] as? String
      }
      if let s = d?["PrimaryService"] as? String { serviceIDs.insert(s) }
    }
    if let store,
      let keys = SCDynamicStoreCopyKeyList(
        store, "State:/Network/Service/.*/(IPv4|IPv6|DNS)" as CFString) as? [String]
    {
      for key in keys {
        let p = key.components(separatedBy: "/")
        if p.count >= 5 { serviceIDs.insert(p[3]) }
      }
    }
    for key in globals
      + serviceIDs.sorted().flatMap({ id in
        ["IPv4", "IPv6"].map { "State:/Network/Service/\(id)/\($0)" }
      })
    {
      let d = dictionary(key)
      var values: [String: [String]] = [:]
      if let router = d?["Router"] as? String { values["Router"] = [router] }
      if let name = (d?["InterfaceName"] ?? d?["PrimaryInterface"]) as? String {
        values["Interface"] = [name]
      }
      values["Family"] = [key.hasSuffix("IPv4") ? "IPv4" : "IPv6"]
      gateways.append(
        .init(
          source: key,
          status: d == nil
            ? (store == nil || SCError() != kSCStatusNoKey ? .unavailable : .notObserved)
            : .available, values: values))
    }
    for key in ["State:/Network/Global/DNS"]
      + serviceIDs.sorted().map({ "State:/Network/Service/\($0)/DNS" })
    {
      let d = dictionary(key)
      var values: [String: [String]] = [:]
      for field in [
        "ServerAddresses", "SearchDomains", "SupplementalMatchDomains", "SupplementalMatchOrders",
        "DomainName",
      ] {
        if let v = d?[field] as? [String] {
          values[field] = v
        } else if let v = d?[field] as? String {
          values[field] = [v]
        } else if let v = d?[field] as? [NSNumber] {
          values[field] = v.map { $0.stringValue }
        }
      }
      dns.append(
        .init(
          source: key,
          status: d == nil
            ? (store == nil || SCError() != kSCStatusNoKey ? .unavailable : .notObserved)
            : .available, values: values))
    }
    let proxy: ConfigurationGroup
    if let raw = SCDynamicStoreCopyProxies(store) as? [String: Any] {
      proxy = Self.safeProxy(raw)
    } else {
      proxy = .init(source: "SCDynamicStoreCopyProxies", status: .unavailable)
    }
    // Capture failure explicitly rather than turning it into a successful empty interface list.
    return NetworkSnapshot(
      path: addressStatus == 0 ? path : "interfacesUnavailable", addresses: local,
      primaryV4: primary4, primaryV6: primary6, gateways: gateways, dns: dns, proxy: proxy)
  }
  public static func prefixLength(_ bytes: [UInt8]) -> Int? {
    var count = 0
    var zero = false
    for byte in bytes {
      for bit in (0..<8).reversed() {
        if byte & (1 << bit) != 0 {
          if zero { return nil }
          count += 1
        } else {
          zero = true
        }
      }
    }
    return count
  }
  public static func safeProxy(_ raw: [String: Any]) -> ConfigurationGroup {
    var values: [String: [String]] = [:]
    for key in [
      "HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable",
      "ProxyAutoDiscoveryEnable", "ExcludeSimpleHostnames",
    ] {
      if let v = raw[key] as? NSNumber { values[key] = [v.boolValue ? "开启" : "关闭"] }
    }
    for key in ["HTTPProxy", "HTTPSProxy", "SOCKSProxy"] {
      if let v = raw[key] as? String { values[key] = [v] }
    }
    for key in ["HTTPPort", "HTTPSPort", "SOCKSPort"] {
      if let v = raw[key] as? NSNumber { values[key] = [v.stringValue] }
    }
    if let v = raw["ExceptionsList"] as? [String] { values["ExceptionsList"] = v }
    if let text = raw["ProxyAutoConfigURLString"] as? String, let url = URLComponents(string: text),
      let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host
    {
      var origin = URLComponents()
      origin.scheme = scheme
      origin.host = host
      origin.port = url.port
      values["PACOrigin"] = [origin.string ?? "未提供"]
    }
    return .init(source: "SCDynamicStoreCopyProxies", status: .available, values: values)
  }
}
private final class ConfigurationCallback {
  let epoch: EventEpoch
  let changed: @Sendable (String) -> Void
  init(epoch: EventEpoch, changed: @escaping @Sendable (String) -> Void) {
    self.epoch = epoch
    self.changed = changed
  }
}
// Callbacks invalidate an epoch synchronously, before queuing actor work (including A→B→A).
public final class NetworkEvents: @unchecked Sendable {
  private var monitor: NWPathMonitor?
  private var store: SCDynamicStore?
  private let queue = DispatchQueue(label: "local.fsy.iprecord.network-events")
  private let lock = NSLock()
  private var path = "unknown"
  private let epoch: EventEpoch
  private let changed: @Sendable (String) -> Void
  public init(epoch: EventEpoch, changed: @escaping @Sendable (String) -> Void) {
    self.epoch = epoch
    self.changed = changed
  }
  public var pathStatus: String {
    lock.lock()
    defer { lock.unlock() }
    return path
  }
  public func start() {
    stop()
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] p in
      guard let self else { return }
      self.lock.lock()
      self.path =
        p.status == .satisfied
        ? "satisfied" : (p.status == .requiresConnection ? "requiresConnection" : "unsatisfied")
      self.lock.unlock()
      self.epoch.bump()
      self.changed("network")
    }
    monitor.start(queue: queue)
    let callback = ConfigurationCallback(epoch: epoch, changed: changed)
    var context = SCDynamicStoreContext(
      version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
      retain: { info in
        return UnsafeRawPointer(
          Unmanaged<ConfigurationCallback>.fromOpaque(info).retain().toOpaque())
      },
      release: { info in
        Unmanaged<ConfigurationCallback>.fromOpaque(info).release()
      }, copyDescription: nil)
    store = SCDynamicStoreCreate(
      nil, "IP Record events" as CFString,
      { _, _, info in
        guard let info else { return }
        let owner = Unmanaged<ConfigurationCallback>.fromOpaque(info).takeUnretainedValue()
        owner.epoch.bump()
        owner.changed("configuration")
      }, &context)
    if let store {
      let patterns = [
        "State:/Network/Global/.*", "State:/Network/Service/.*/(IPv4|IPv6|DNS|Proxies)",
        "State:/Network/Interface/.*/(IPv4|IPv6|Link)", "Setup:/Network/.*",
      ]
      SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
      SCDynamicStoreSetDispatchQueue(store, queue)
    }
  }
  public func stop() {
    monitor?.cancel()
    monitor = nil
    if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    store = nil
  }
  deinit { stop() }
}
