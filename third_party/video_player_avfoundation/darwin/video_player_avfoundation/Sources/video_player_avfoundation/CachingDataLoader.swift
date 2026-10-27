// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CommonCrypto
import Foundation

/// 单个原始 URL 对应的字节加载器。
///
/// 职责：
/// - 同一份 HTTP 下载，把字节同时分发给所有挂上来的 `AVAssetResourceLoadingRequest`；
/// - 边下载边写入缓存文件，下次命中直接读本地，不发 HTTP。
///
/// 仅服务渐进式视频（MP4 等），不处理 HLS 分片。
final class CachingDataLoader: NSObject, URLSessionDataDelegate {

  private let originalURLString: String
  private let cacheFile: URL

  private var fileHandle: FileHandle?
  /// 已写入缓存文件的字节数（同时用于判断 loadingRequest 可服务范围）。
  private var downloadedBytes: Int64 = 0
  /// 远端资源总字节数；收到 Content-Length 后写入，用于限制 fill 的读取上限。
  private var contentLength: Int64 = 0

  private var loadingRequests: [AVAssetResourceLoadingRequest] = []
  private var dataTask: URLSessionDataTask?
  private let callbackQueue = OperationQueue()
  /// 串行队列保护所有可变状态；delegate 回调通过 lockQueue.async 转入。
  private let lockQueue = DispatchQueue(label: "io.flutter.videoplayer.cache.dataloader")

  private enum State { case idle, loading, finished, failed, cancelled }
  private var state: State = .idle

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 600
    callbackQueue.maxConcurrentOperationCount = 1
    callbackQueue.qualityOfService = .userInitiated
    return URLSession(configuration: config, delegate: self, delegateQueue: callbackQueue)
  }()

  init(originalURLString: String, cacheDirectory: URL) {
    self.originalURLString = originalURLString
    let hash = CachingDataLoader.sha256(originalURLString)
    self.cacheFile = cacheDirectory.appendingPathComponent(hash)
    super.init()
  }

  // MARK: - Public

  func start() {
    lockQueue.async { [weak self] in
      guard let self = self, self.state == .idle else { return }

      // 缓存命中判断：只用本地文件大小，不发 HEAD 请求，避免阻塞锁队列。
      // contentLength 在首次响应时写入；启动阶段若文件存在且非空，先尝试播放，
      // 下载完成后 state 变 finished，后续请求直接从文件读。
      if let attrs = try? FileManager.default.attributesOfItem(atPath: self.cacheFile.path),
        let size = attrs[.size] as? Int64, size > 0
      {
        self.downloadedBytes = size
        // 暂不标记 finished，等下载验证或第一次 response 确认完整性。
        // 若文件已完整，kickOffDownload 会因 Range 返回 416 或 Content-Range 判断。
      }

      self.state = .loading
      self.openFileForWriting()
      self.kickOffDownload()
    }
  }

  func add(_ request: AVAssetResourceLoadingRequest) {
    lockQueue.async { [weak self] in
      guard let self = self else { return }
      // 先填充 contentInformationRequest（AVPlayer 用它获取文件总长度和 MIME）。
      self.fillContentInformation(for: request)
      self.loadingRequests.append(request)
      self.tryServe(request)
    }
  }

  func cancel(_ request: AVAssetResourceLoadingRequest) {
    lockQueue.async { [weak self] in
      guard let self = self else { return }
      self.loadingRequests.removeAll { $0 === request }
      request.finishLoading()
    }
  }

  func cancelAll() {
    lockQueue.async { [weak self] in
      guard let self = self else { return }
      self.state = .cancelled
      self.dataTask?.cancel()
      self.dataTask = nil
      let pending = self.loadingRequests
      self.loadingRequests.removeAll()
      for r in pending { r.finishLoading() }
      try? self.fileHandle?.close()
      self.fileHandle = nil
    }
  }

  // MARK: - Internal

  private func openFileForWriting() {
    // 若已有部分缓存，追加写入；否则新建。
    if !FileManager.default.fileExists(atPath: cacheFile.path) {
      FileManager.default.createFile(atPath: cacheFile.path, contents: nil)
    }
    do {
      fileHandle = try FileHandle(forWritingTo: cacheFile)
      if downloadedBytes > 0 {
        try fileHandle?.seek(toOffset: UInt64(downloadedBytes))
      }
    } catch {
      fileHandle = nil
    }
  }

  private func kickOffDownload() {
    guard let url = URL(string: originalURLString) else {
      state = .failed
      flushPendingRequests(with: NSError(
        domain: "VideoCache", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(originalURLString)"]))
      return
    }
    var request = URLRequest(url: url)
    // 断点续传：从已下载字节后开始请求。
    if downloadedBytes > 0 {
      request.setValue("bytes=\(downloadedBytes)-", forHTTPHeaderField: "Range")
    }
    let task = session.dataTask(with: request)
    dataTask = task
    task.resume()
  }

  // MARK: - URLSessionDataDelegate

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse {
      // 服务器返回 416（Range Not Satisfiable）表示文件已完整缓存。
      if http.statusCode == 416 {
        lockQueue.async { [weak self] in
          guard let self = self else { return }
          try? self.fileHandle?.close()
          self.fileHandle = nil
          self.state = .finished
          self.flushPendingRequests()
        }
        completionHandler(.cancel)
        return
      }
      // 记录内容总长度（200 用 Content-Length，206 用 Content-Range 解析）。
      if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range") {
        // "bytes 200-1000/1234" → total = 1234
        if let total = rangeHeader.split(separator: "/").last.flatMap({ Int64($0) }) {
          lockQueue.async { [weak self] in self?.contentLength = total }
        }
      } else if let cl = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
        lockQueue.async { [weak self] in self?.contentLength = cl }
      }
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
  ) {
    lockQueue.async { [weak self] in
      guard let self = self, self.state == .loading else { return }
      self.appendToFile(data)
      self.downloadedBytes += Int64(data.count)
      // contentInformation 需要 contentLength，可能在第一批数据后才确定。
      for r in self.loadingRequests { self.fillContentInformation(for: r) }
      self.tryServeAll()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    lockQueue.async { [weak self] in
      guard let self = self else { return }
      try? self.fileHandle?.close()
      self.fileHandle = nil
      if let error = error {
        // 取消不算失败（cancelAll 主动触发）。
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        self.state = .failed
        self.flushPendingRequests(with: error)
      } else {
        self.state = .finished
        self.flushPendingRequests()
      }
    }
  }

  // MARK: - Serving

  private func appendToFile(_ data: Data) {
    guard let handle = fileHandle else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      fileHandle = nil
    }
  }

  /// 填充 AVAssetResourceLoadingRequest 的 contentInformationRequest。
  ///
  /// AVPlayer 在真正请求字节之前会先发一个 contentInformationRequest 探测文件长度和类型；
  /// 必须填写否则 AVPlayer 不会继续发数据请求。
  private func fillContentInformation(for request: AVAssetResourceLoadingRequest) {
    guard let info = request.contentInformationRequest,
      info.contentLength == 0,
      contentLength > 0
    else { return }
    info.contentLength = contentLength
    info.contentType = "public.mpeg-4"  // AVFileTypeMPEG4 对应的 UTI
    info.isByteRangeAccessSupported = true
  }

  private func tryServe(_ request: AVAssetResourceLoadingRequest) {
    // contentInformationRequest-only 请求（无 dataRequest）直接完成。
    guard let dataRequest = request.dataRequest else {
      if request.contentInformationRequest != nil && contentLength > 0 {
        request.finishLoading()
        loadingRequests.removeAll { $0 === request }
      }
      return
    }

    let offset = Int64(dataRequest.currentOffset)
    // requestedLength 可能是 Int.max；用 contentLength 或 downloadedBytes 限制上限。
    let maxAvailable = max(downloadedBytes, contentLength)
    let rawLength = Int64(dataRequest.requestedLength)
    let safeLength: Int64
    if rawLength <= 0 || rawLength == Int64(Int.max) {
      // AVPlayer 未指定长度时，提供到当前已下载末尾的数据。
      safeLength = downloadedBytes - offset
    } else {
      safeLength = min(rawLength, maxAvailable - offset)
    }

    guard safeLength > 0, offset >= 0, downloadedBytes >= offset + safeLength else { return }
    fill(request, offset: offset, length: safeLength)
  }

  private func tryServeAll() {
    for request in loadingRequests {
      tryServe(request)
    }
  }

  private func fill(_ request: AVAssetResourceLoadingRequest, offset: Int64, length: Int64) {
    do {
      let handle = try FileHandle(forReadingFrom: cacheFile)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: Int(length)) ?? Data()
      request.dataRequest?.respond(with: data)
      // 若数据量已满足请求或是文件末尾则完成，否则等待更多下载。
      let satisfied = Int64(data.count) >= length || state == .finished
      if satisfied {
        request.finishLoading()
        loadingRequests.removeAll { $0 === request }
      }
    } catch {
      request.finishLoading(with: error)
      loadingRequests.removeAll { $0 === request }
    }
  }

  private func flushPendingRequests(with error: Error? = nil) {
    let pending = loadingRequests
    loadingRequests.removeAll()
    if state == .finished {
      for r in pending {
        if let dataReq = r.dataRequest {
          // 补填剩余数据。
          let offset = Int64(dataReq.currentOffset)
          let length = downloadedBytes - offset
          if length > 0 { fill(r, offset: offset, length: length) }
          else { r.finishLoading() }
        } else {
          r.finishLoading()
        }
      }
    } else {
      for r in pending { r.finishLoading(with: error) }
    }
  }

  // MARK: - SHA-256

  private static func sha256(_ string: String) -> String {
    let data = Data(string.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
      _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }
}
