import CXDB
import CryptoKit
import Foundation

public struct DatabaseIdentity: Sendable {
  public let family: Family
  public let bytes: Int
  public let hash: String
  public let generated: String
  public static let bundled: [DatabaseIdentity] = [
    .init(
      family: .v4, bytes: 11_122_036,
      hash: "8e31bbdccb5bf21028af10592d4312ec975da0bffa108c0c5d862a12190f9ad3",
      generated: "2026-08-28T04:43:01Z"),
    .init(
      family: .v6, bytes: 37_277_813,
      hash: "939f6b46bd2b8bec3cf7c5ceb8ba782266ae9b1f35b5ba7916700dec0b7506ed",
      generated: "2026-08-14T05:38:41Z"),
  ]
}
// C pointers never leave this private owner. It is only accessed inside GeoResolver.
private final class XDBHandle: @unchecked Sendable {
  var searcher = xdb_searcher_t()
  var opened = false
  init(url: URL, family: Family) throws {
    guard xdb_verify_from_file(url.path) == 0,
      xdb_new_with_file_only(
        family == .v4 ? xdb_version_v4() : xdb_version_v6(), &searcher, url.path) == 0
    else { throw RecordError.message("归属数据库读取失败") }
    opened = true
  }
  deinit { if opened { xdb_close(&searcher) } }
  func lookup(_ address: IPAddress, hash: String) -> GeoResult {
    var region = xdb_region_buffer_t()
    guard xdb_region_buffer_init(&region, nil, 0) == 0 else {
      return .init(status: "unavailable", databaseHash: hash)
    }
    defer { xdb_region_buffer_free(&region) }
    guard xdb_search_by_string(&searcher, address.text, &region) == 0, region.length <= 65535 else {
      return .init(status: "unavailable", databaseHash: hash)
    }
    guard region.length > 0 else { return .init(status: "not_found", databaseHash: hash) }
    guard let pointer = region.value,
      let text = String(data: Data(bytes: pointer, count: region.length), encoding: .utf8)
    else { return .init(status: "unavailable", databaseHash: hash) }
    let fields = text.components(separatedBy: "|").map {
      $0.isEmpty || $0 == "0" ? nil : Optional($0)
    }
    guard fields.count == 5 else { return .init(status: "unavailable", databaseHash: hash) }
    return .init(
      status: "found", country: fields[0], province: fields[1], city: fields[2], isp: fields[3],
      countryCode: fields[4], databaseHash: hash)
  }
}
public actor GeoResolver {
  private let directory: URL
  private var readers: [Family: XDBHandle] = [:]
  private var health: [Family: String] = [:]
  private var cache: [String: GeoResult] = [:]
  private var cacheOrder: [String] = []
  public init(directory: URL) { self.directory = directory }
  public static func validateHeader(_ data: Data, length: Int, family: Family) throws {
    guard data.count == 256 else { throw RecordError.message("归属数据库头不完整") }
    func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
    func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
    let start = u32(8)
    let end = u32(12)
    let size = family == .v4 ? 14 : 38
    guard u16(0) == 3, u16(18) == 4, u16(16) == family.rawValue,
      start >= 256 + 524288, end >= start, (end - start) % size == 0, end + size <= length
    else { throw RecordError.message("归属数据库结构或地址族不匹配") }
  }
  public static func validateFile(_ url: URL, identity: DatabaseIdentity) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let length = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    guard length == identity.bytes else { throw RecordError.message("归属数据库长度校验失败") }
    let header = try handle.read(upToCount: 256) ?? Data()
    try validateHeader(header, length: Int(length), family: identity.family)
    try handle.seek(toOffset: 0)
    var sha = SHA256()
    while try autoreleasepool(invoking: {
      guard let block = try handle.read(upToCount: 65536), !block.isEmpty else { return false }
      sha.update(data: block)
      return true
    }) {}
    guard sha.finalize().map({ String(format: "%02x", $0) }).joined() == identity.hash else {
      throw RecordError.message("归属数据库完整性校验失败")
    }
  }
  public func prepare() {
    for identity in DatabaseIdentity.bundled where health[identity.family] == nil {
      do {
        let url = directory.appendingPathComponent("ip2region_v\(identity.family.rawValue).xdb")
        try Self.validateFile(url, identity: identity)
        readers[identity.family] = try XDBHandle(url: url, family: identity.family)
        health[identity.family] = "已校验 · 文件读取模式"
      } catch { health[identity.family] = "不可用：\(error.localizedDescription)" }
    }
  }
  public func databaseHealth() -> [Family: String] {
    prepare()
    return health
  }
  public func lookup(_ address: IPAddress) -> GeoResult {
    guard address.isPublic else { return .init(status: "non_public") }
    prepare()
    let identity = DatabaseIdentity.bundled.first { $0.family == address.family }!
    let key = address.text + identity.hash
    if let cached = cache[key] { return cached }
    let result =
      readers[address.family]?.lookup(address, hash: identity.hash)
      ?? .init(status: "unavailable", databaseHash: identity.hash)
    if cacheOrder.count >= 128 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    cacheOrder.append(key)
    cache[key] = result
    return result
  }
}
