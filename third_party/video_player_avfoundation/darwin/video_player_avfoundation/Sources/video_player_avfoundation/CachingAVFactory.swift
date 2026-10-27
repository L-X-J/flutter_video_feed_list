// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

/// 缓存版 AVObjectFactory。
///
/// 当前阶段：透传所有请求给默认实现，确认播放链路可用。
/// 缓存机制（AVAssetResourceLoaderDelegate）在播放稳定后再启用。
final class CachingAVFactory: DefaultAVFactory {

  override func urlAsset(with url: URL, options: [String: Any]?) -> any WrappedAVAsset {
    return super.urlAsset(with: url, options: options)
  }

  override func playerItem(with asset: any WrappedAVAsset) -> any WrappedAVPlayerItem {
    return super.playerItem(with: asset)
  }
}

