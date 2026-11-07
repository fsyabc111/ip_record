import Foundation
import CryptoKit
import Darwin

public enum Family: Int, Codable, Sendable, CaseIterable { case v4 = 4, v6 = 6
    public var label: String { self == .v4 ? "IPv4" : "IPv6" }
    public var endpoint: String { self == .v4 ? "https://api.ipify.org" : "https://api6.ipify.org" }
}
public struct IPAddress: Codable, Hashable, Sendable {
    public let text: String
    public let family: Family
    public let bytes: [UInt8]
    public let scope: String?
    public init?(_ input: String) {
        let parts = input.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty else { return nil }
        let bare = String(parts[0])
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            guard parts.count == 1 else { return nil }
            family = .v4; bytes = withUnsafeBytes(of: v4) { Array($0) }; scope = nil
            text = bytes.map(String.init).joined(separator: ".")
        } else if inet_pton(AF_INET6, bare, &v6) == 1 {
            let raw = withUnsafeBytes(of: v6) { Array($0) }
            if raw.prefix(10).allSatisfy({ $0 == 0 }) && raw[10] == 255 && raw[11] == 255 {
                family = .v4; bytes = Array(raw.suffix(4)); scope = nil
                text = bytes.map(String.init).joined(separator: ".")
            } else {
                family = .v6; bytes = raw
                scope = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : nil
                var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &v6, &out, socklen_t(out.count)) != nil else { return nil }
                text = String(decoding: out.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased() + (scope.map { "%" + $0 } ?? "")
            }
        } else { return nil }
    }
    public var scopeLabel: String {
        if family == .v4 {
            let b = bytes
            if b[0] == 0 { return "未指定／保留" }
            if b[0] == 127 { return "回环" }
            if b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) { return "私有" }
            if b[0] == 169 && b[1] == 254 { return "链路本地" }
            if b[0] == 100 && (64...127).contains(b[1]) { return "共享地址" }
            if b[0] >= 224 { return "组播／保留" }
            if (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) || (b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) || (b[0] == 203 && b[1] == 0 && b[2] == 113) || (b[0] == 192 && b[1] == 88 && b[2] == 99) { return "特殊／文档" }
            return "公网单播"
        }
        if bytes.allSatisfy({ $0 == 0 }) { return "未指定／保留" }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return "回环" }
        if bytes[0] == 255 { return "组播／保留" }
        if bytes[0] & 254 == 252 { return "ULA 私有" }
        if bytes[0] == 254 && bytes[1] & 192 == 128 { return "链路本地" }
        if bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return "特殊／文档" }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return "特殊／文档" }
        // Only currently allocated global unicast, excluding special-purpose 2001::/23.
        if bytes[0] & 224 == 32 {
            if bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] < 2 { return "特殊／文档" }
            return "公网单播"
        }
        return "特殊／保留"
    }
    public var isPublic: Bool { scope == nil && scopeLabel == "公网单播" }
    public var isDisplayable: Bool { !["未指定／保留", "回环", "组播／保留"].contains(scopeLabel) }
    public var sortKey: String { bytes.map { String(format: "%02x", $0) }.joined() + (scope ?? "") }
}
public enum ReadStatus: String, Codable, Sendable { case available, notObserved, unavailable }
public struct LocalAddress: Codable, Hashable, Sendable, Identifiable {
    public var interface: String; public var type: String; public var ip: IPAddress; public var prefix: Int?
    public var id: String { interface + ":" + ip.text }
    public init(interface: String, type: String, ip: IPAddress, prefix: Int? = nil) { self.interface = interface; self.type = type; self.ip = ip; self.prefix = prefix }
}
public struct ConfigurationGroup: Codable, Equatable, Sendable {
    public var source: String; public var status: ReadStatus; public var values: [String: [String]]
    public init(source: String, status: ReadStatus, values: [String: [String]] = [:]) { self.source = source; self.status = status; self.values = values }
}
public struct NetworkSnapshot: Codable, Equatable, Sendable {
    public var path: String
    public var addresses: [LocalAddress]
    public var primaryV4: String?; public var primaryV6: String?
    public var gateways: [ConfigurationGroup]; public var dns: [ConfigurationGroup]; public var proxy: ConfigurationGroup
    public var dnsCoverage = "partial"
    public init(path: String = "unknown", addresses: [LocalAddress] = [], primaryV4: String? = nil, primaryV6: String? = nil, gateways: [ConfigurationGroup] = [], dns: [ConfigurationGroup] = [], proxy: ConfigurationGroup = .init(source: "system", status: .notObserved)) {
        self.path = path; self.addresses = Array(Set(addresses)).sorted { ($0.interface, $0.ip.sortKey) < ($1.interface, $1.ip.sortKey) }; self.primaryV4 = primaryV4; self.primaryV6 = primaryV6; self.gateways = gateways; self.dns = dns; self.proxy = proxy
    }
    public var fingerprint: String { digest(self) }
    public var preferredV4: LocalAddress? {
        addresses.filter { $0.ip.family == .v4 }.sorted {
            let a = $0.interface == primaryV4 ? 0 : (["Wi-Fi", "以太网"].contains($0.type) ? 1 : 2)
            let b = $1.interface == primaryV4 ? 0 : (["Wi-Fi", "以太网"].contains($1.type) ? 1 : 2)
            return a == b ? ($0.interface, $0.ip.sortKey) < ($1.interface, $1.ip.sortKey) : a < b
        }.first
    }
}
public struct GeoResult: Codable, Equatable, Sendable {
    public var status: String; public var country: String?; public var province: String?; public var city: String?; public var isp: String?; public var countryCode: String?; public var databaseHash: String?
    public init(status: String, country: String? = nil, province: String? = nil, city: String? = nil, isp: String? = nil, countryCode: String? = nil, databaseHash: String? = nil) { self.status = status; self.country = country; self.province = province; self.city = city; self.isp = isp; self.countryCode = countryCode; self.databaseHash = databaseHash }
    public var location: String {
        if status == "unavailable" { return "归属数据库不可用" }
        let localized = countryCode.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) } ?? country
        var names: [String] = []
        for name in [localized, province, city].compactMap({ $0 }) where names.last != name { names.append(name) }
        return names.isEmpty ? "归属地未知" : names.joined(separator: " · ")
    }
}
public struct KnownAddress: Codable, Equatable, Sendable {
    public var address: IPAddress; public var confirmedAt: Date; public var contextID: String; public var endpoint: String; public var geo: GeoResult?
}
public struct ProbeResult: Codable, Equatable, Sendable {
    public var family: Family; public var status: String; public var address: IPAddress?; public var error: String?; public var httpStatus: Int?
    public var startedAt: Date; public var completedAt: Date; public var endpoint: String
    public var geo: GeoResult?; public var lastKnown: KnownAddress?
    public init(family: Family, status: String, address: IPAddress? = nil, error: String? = nil, httpStatus: Int? = nil, startedAt: Date = Date(), completedAt: Date = Date()) { self.family = family; self.status = status; self.address = address; self.error = error; self.httpStatus = httpStatus; self.startedAt = startedAt; self.completedAt = completedAt; endpoint = family.endpoint }
    public var signaturePart: String { [status, address?.text ?? "", error ?? "", httpStatus.map(String.init) ?? ""].joined(separator: "|") }
}
public struct Observation: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var contextID: String; public var epoch: UInt64
    public var startedAt: Date; public var completedAt: Date; public var timezoneOffset: Int; public var uptime: TimeInterval
    public var triggers: [String]; public var consistency: String
    public var network: NetworkSnapshot; public var v4: ProbeResult; public var v6: ProbeResult
    public init(contextID: String, epoch: UInt64, startedAt: Date, completedAt: Date, triggers: [String], consistency: String = "stable", network: NetworkSnapshot, v4: ProbeResult, v6: ProbeResult) {
        self.contextID = contextID; self.epoch = epoch; self.startedAt = startedAt; self.completedAt = completedAt; timezoneOffset = TimeZone.current.secondsFromGMT(for: startedAt); uptime = ProcessInfo.processInfo.systemUptime; self.triggers = triggers.sorted(); self.consistency = consistency; self.network = network; self.v4 = v4; self.v6 = v6
    }
    public var fingerprint: String { digest([network.fingerprint, consistency, v4.signaturePart, v6.signaturePart]) }
    public func known(_ family: Family) -> KnownAddress? {
        let p = family == .v4 ? v4 : v6
        if p.status == "confirmed", let address = p.address { return KnownAddress(address: address, confirmedAt: p.completedAt, contextID: contextID, endpoint: p.endpoint, geo: p.geo) }
        return p.lastKnown
    }
    public var searchText: String {
        let geo = [v4.geo, v6.geo].compactMap { $0 }.flatMap { [$0.country, $0.province, $0.city, $0.isp, $0.countryCode, $0.location].compactMap { $0 } }
        return ([v4.address?.text, v6.address?.text].compactMap { $0 } + network.addresses.flatMap { [$0.interface, $0.ip.text] } + geo).joined(separator: " ")
    }
    public func changes(from old: Observation?) -> [String] {
        guard let old else { return ["观测起点"] }
        var tags: [String] = []
        if v4.address != old.v4.address || v6.address != old.v6.address { tags.append("公网地址") }
        if network.addresses != old.network.addresses || network.primaryV4 != old.network.primaryV4 || network.primaryV6 != old.network.primaryV6 { tags.append("本机地址") }
        if network.path != old.network.path || consistency != old.consistency { tags.append("连接状态") }
        if network.dns != old.network.dns { tags.append("DNS") }; if network.gateways != old.network.gateways { tags.append("网关") }; if network.proxy != old.network.proxy { tags.append("代理") }
        if v4.status != old.v4.status || v6.status != old.v6.status || v4.error != old.v4.error || v6.error != old.v6.error || v4.httpStatus != old.v4.httpStatus || v6.httpStatus != old.v6.httpStatus { tags.append("查询状态") }
        return tags.isEmpty ? ["网络状态"] : tags
    }
}
public func jsonEncoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .millisecondsSince1970; return e }
public func jsonDecoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }
public func digest<T: Encodable>(_ value: T) -> String { SHA256.hash(data: (try? jsonEncoder().encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
public enum RecordError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): s } }
}
public final class EventEpoch: @unchecked Sendable {
    private let lock = NSLock(); private var counter: UInt64 = 0
    public init() {}
    @discardableResult public func bump() -> UInt64 { lock.lock(); defer { lock.unlock() }; counter &+= 1; return counter }
    public var value: UInt64 { lock.lock(); defer { lock.unlock() }; return counter }
}
