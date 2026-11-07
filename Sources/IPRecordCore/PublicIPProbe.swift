import Foundation

public protocol IPProbing: Sendable { func probe(_ family: Family) async -> ProbeResult }
public struct PublicIPProbe: IPProbing {
  private let configuration: @Sendable () -> URLSessionConfiguration
  public init(
    configuration: @escaping @Sendable () -> URLSessionConfiguration = {
      URLSessionConfiguration.ephemeral
    }
  ) { self.configuration = configuration }
  public func probe(_ family: Family) async -> ProbeResult {
    let request = ProbeRequest(family: family, configuration: configuration())
    return await withTaskCancellationHandler {
      await request.run()
    } onCancel: {
      request.cancel()
    }
  }
  public static func validate(_ data: Data, family: Family) -> (IPAddress?, String?) {
    guard data.count <= 1024 else { return (nil, "oversized") }
    guard let text = String(data: data, encoding: .utf8) else { return (nil, "invalidAddress") }
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{0b}\u{0c}"))
    guard let address = IPAddress(trimmed), address.isPublic else { return (nil, "invalidAddress") }
    guard address.family == family else { return (nil, "familyMismatch") }
    return (address, nil)
  }
}
// URLSession invokes this owner's delegate on a serial queue. Completion/cancellation is locked.
private final class ProbeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let family: Family
  private let configuration: URLSessionConfiguration
  private var continuation: CheckedContinuation<ProbeResult, Never>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var deadline: DispatchWorkItem?
  private var done = false
  private var cancelled = false
  private var body = Data()
  private var failure: String?
  private var httpStatus: Int?
  private let started = Date()
  init(family: Family, configuration: URLSessionConfiguration) {
    self.family = family
    self.configuration = configuration
  }
  func run() async -> ProbeResult {
    await withCheckedContinuation { continuation in
      lock.lock()
      if cancelled {
        lock.unlock()
        continuation.resume(
          returning: .init(
            family: family, status: "cancelled", error: "cancelled", startedAt: started))
        return
      }
      self.continuation = continuation
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCredentialStorage = nil
      configuration.timeoutIntervalForRequest = 6
      configuration.timeoutIntervalForResource = 8
      configuration.waitsForConnectivity = false
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      self.session = session
      var request = URLRequest(
        url: URL(string: family.endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 6)
      request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
      request.setValue("no-cache", forHTTPHeaderField: "Pragma")
      let task = session.dataTask(with: request)
      self.task = task
      let deadline = DispatchWorkItem { [weak self] in self?.finish(error: "timeout") }
      self.deadline = deadline
      lock.unlock()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
      task.resume()
    }
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
    finish(error: "cancelled")
  }
  private func finish(error: String? = nil) {
    lock.lock()
    guard !done, let continuation else {
      lock.unlock()
      return
    }
    done = true
    self.continuation = nil
    let failure = error ?? self.failure
    let parsed = PublicIPProbe.validate(body, family: family)
    let finalError = failure ?? parsed.1
    let result = ProbeResult(
      family: family,
      status: finalError == nil
        ? "confirmed" : (finalError == "cancelled" ? "cancelled" : "failed"),
      address: finalError == nil ? parsed.0 : nil, error: finalError, httpStatus: httpStatus,
      startedAt: started, completedAt: Date())
    let session = self.session
    let task = self.task
    self.session = nil
    self.task = nil
    deadline?.cancel()
    deadline = nil
    lock.unlock()
    task?.cancel()
    session?.invalidateAndCancel()
    continuation.resume(returning: result)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(error: "http")
      return
    }
    lock.lock()
    httpStatus = response.statusCode
    lock.unlock()
    guard response.statusCode == 200 else {
      completionHandler(.cancel)
      finish(
        error: response.statusCode == 401 || response.statusCode == 407 ? "authentication" : "http")
      return
    }
    guard response.expectedContentLength <= 1024 else {
      completionHandler(.cancel)
      finish(error: "oversized")
      return
    }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let oversized = body.count + data.count > 1024
    if !oversized { body.append(data) }
    lock.unlock()
    if oversized { finish(error: "oversized") }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    if metrics.transactionMetrics.contains(where: { $0.resourceFetchType == .localCache }) {
      finish(error: "cachedResponse")
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    if let error {
      let code = (error as NSError).code
      let category: String
      switch code {
      case NSURLErrorCancelled: category = "cancelled"
      case NSURLErrorTimedOut: category = "timeout"
      case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: category = "dns"
      case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
        category = "tls"
      case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
        category = "authentication"
      default: category = "connection"
      }
      finish(error: category)
    } else {
      finish()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    finish(error: "redirect")
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      finish(error: "authentication")
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      finish(error: "authentication")
    }
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    willCacheResponse proposedResponse: CachedURLResponse,
    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
  ) { completionHandler(nil) }
}
