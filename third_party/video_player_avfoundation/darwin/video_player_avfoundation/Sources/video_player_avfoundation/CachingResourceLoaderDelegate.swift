// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Foundation

/// 单流缓存：通过 `AVAssetResourceLoaderDelegate` 接管 AVPlayer 的字节请求，
/// 在同一份下载中既喂给播放器又写入磁盘。下次命中缓存时直接读取本地文件。
///
/// 仅适用于渐进式视频（MP4 等），HLS（`.m3u8`）由调用方跳过本机制。
final class CachingResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

  /// 自定义 URL scheme，AVPlayer 看到 `cachevp://` 才会触发本委托。
  static let scheme = "cachevp"

  /// 缓存根目录，默认放在 `<Caches>/VideoCache`。
  private let cacheDir: URL

  /// 内存中的加载任务，按原始 URL 索引，保证同一资源只有一份下载在进行。
  private var loaders: [String: CachingDataLoader] = [:]

  /// 串行队列，保护 `loaders` 字典的读写（所有 ResourceLoader 回调均在此队列执行）。
  private let lockQueue = DispatchQueue(label: "io.flutter.videoplayer.cache.delegate")

  init(cacheDirectory: URL? = nil) {
    let base =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let resolved = cacheDirectory ?? base.appendingPathComponent("VideoCache", isDirectory: true)
    self.cacheDir = resolved
    super.init()
    try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
  }

  // MARK: - AVAssetResourceLoaderDelegate

  /// 拦截自定义 scheme 的加载请求；返回 true 表示由本委托负责完成。
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let url = loadingRequest.request.url,
      url.scheme == CachingResourceLoaderDelegate.scheme
    else {
      return false
    }
    let originalURLString = Self.originalURL(from: url)
    let loader = getOrCreateLoader(for: originalURLString)
    loader.add(loadingRequest)
    return true
  }

  /// 取消加载时把请求从 loader 中摘掉，避免悬空回调。
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    guard let url = loadingRequest.request.url else { return }
    let originalURLString = Self.originalURL(from: url)
    lockQueue.async { [weak self] in
      self?.loaders[originalURLString]?.cancel(loadingRequest)
    }
  }

  // MARK: - Internal

  /// 取出已存在的 loader，或在不持有锁的情况下竞态安全地创建一个新 loader。
  private func getOrCreateLoader(for originalURLString: String) -> CachingDataLoader {
    return lockQueue.sync {
      if let existing = loaders[originalURLString] { return existing }
      let loader = CachingDataLoader(originalURLString: originalURLString, cacheDirectory: cacheDir)
      loaders[originalURLString] = loader
      // start() 内部异步执行，不需要在锁内等待。
      loader.start()
      return loader
    }
  }

  /// 把自定义 scheme 还原为原始 HTTPS URL 字符串。
  private static func originalURL(from url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "https"
    return components?.url?.absoluteString ?? url.absoluteString
  }

  /// 释放所有未完成的下载任务；页面销毁时调用，避免悬空任务持有 AVAsset。
  func invalidate() {
    lockQueue.sync {
      let all = Array(loaders.values)
      loaders.removeAll()
      for loader in all { loader.cancelAll() }
    }
  }
}
