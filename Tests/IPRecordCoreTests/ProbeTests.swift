import Foundation
import Testing

@testable import IPRecordCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let mode = request.value(forHTTPHeaderField: "X-Test-Mode") ?? "success"
    if mode == "timeout" {
      client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
      return
    }
    if mode == "dns" {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    if mode == "tls" {
      client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
      return
    }
    let status = mode == "http" ? 403 : 200
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!,
      cacheStoragePolicy: .notAllowed)
    if mode == "oversized" {
      client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 1025))
    } else if mode == "invalid" {
      client?.urlProtocol(self, didLoad: Data("<html>not an IP</html>".utf8))
    } else {
      client?.urlProtocol(self, didLoad: Data("8.8.8.8".utf8))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
private func stubProbe(_ mode: String) -> PublicIPProbe {
  PublicIPProbe(configuration: {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-Mode": mode]
    return config
  })
}
@Test func sessionTransportHandlesHTTPAndStreamLimits() async {
  let success = await stubProbe("success").probe(.v4)
  #expect(success.status == "confirmed")
  #expect(success.address?.text == "8.8.8.8")
  for (mode, category) in [
    ("http", "http"), ("oversized", "oversized"), ("invalid", "invalidAddress"),
    ("timeout", "timeout"), ("dns", "dns"), ("tls", "tls"),
  ] {
    let result = await stubProbe(mode).probe(.v4)
    #expect(result.status == "failed")
    #expect(result.error == category)
    #expect(result.address == nil)
  }
  #expect(await stubProbe("success").probe(.v6).error == "familyMismatch")
}
@Test func cancelledProbeCannotBecomeSuccessful() async {
  let task = Task { await stubProbe("success").probe(.v4) }
  task.cancel()
  #expect(await task.value.status == "cancelled")
}
