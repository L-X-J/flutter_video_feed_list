// 控制器工厂：创建并初始化 VideoPlayerController。
//
// 网络视频统一通过本地缓存代理服务器（VideoCacheProxyServer）中转：
// - 代理层负责单流边播边缓存，player 始终拿到 127.0.0.1 地址
// - 本地文件直接用 file 控制器，不经过代理
// - HLS（.m3u8）跳过代理，直接使用原始 URL（分片流不适合整文件缓存）
import 'dart:io' show File;

import 'package:flutter_video_feed_list/src/utils/logging.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import 'video_cache_proxy_server.dart';

/// 控制器工厂：创建并初始化 [VideoPlayerController]。
///
/// 网络视频走本地代理实现边播边缓存；本地文件和 HLS 直通。
class VideoControllerFactory {
  VideoControllerFactory();

  /// 创建并初始化控制器。
  ///
  /// - [item] 视频条目，需包含 `videoUrl` 与唯一 `key`
  /// - [viewType] 视图类型（TextureView/PlatformView）
  /// - [loop] 是否循环播放
  /// - [volume] 初始音量
  ///
  /// 返回已初始化的 [VideoPlayerController]；失败时返回 `null`。
  Future<VideoPlayerController?> createAndInit(
    IVideoItem item, {
    required VideoViewType viewType,
    required bool loop,
    required double volume,
    VideoPlayerOptions? videoPlayerOptions,
  }) async {
    final originalUri = Uri.parse(item.videoUrl);

    final VideoPlayerController controller;
    if (originalUri.scheme == 'file') {
      // 本地文件直接用 file 控制器，不经过代理。
      logging('[factory] file ${item.key}');
      controller = VideoPlayerController.file(
        File.fromUri(originalUri),
        viewType: viewType,
        videoPlayerOptions: videoPlayerOptions,
      );
    } else {
      // 网络视频：非 HLS 走本地代理实现边播边缓存；HLS 直接使用原始 URL。
      final useProxy = _shouldUseProxy(item.videoUrl);
      final playUrl = useProxy ? await _proxyUrl(item.videoUrl) : item.videoUrl;
      logging('[factory] ${useProxy ? "proxy" : "direct"} ${item.key} → ${_shortUrl(playUrl)}');
      controller = VideoPlayerController.networkUrl(
        Uri.parse(playUrl),
        viewType: viewType,
        videoPlayerOptions: videoPlayerOptions,
      );
    }

    try {
      logging('[factory] init start ${item.key}');
      await controller.initialize().timeout(const Duration(seconds: 30));
      await controller.setLooping(loop);
      try {
        await controller.setVolume(volume);
      } catch (_) {}
      final s = controller.value.size;
      logging('[factory] init ok ${item.key} ${s.width}x${s.height} type=$viewType');
      return controller;
    } catch (e) {
      logging('[factory] init FAIL ${item.key}: $e');
      await controller.dispose();
      // 若 texture 模式失败，降级到 platformView 重试一次（使用原始 URL 规避代理异常）。
      if (viewType != VideoViewType.platformView &&
          originalUri.scheme != 'file') {
        try {
          logging('[factory] fallback platformView ${item.key}');
          final fallback = VideoPlayerController.networkUrl(
            originalUri,
            viewType: VideoViewType.platformView,
            videoPlayerOptions: videoPlayerOptions,
          );
          await fallback.initialize().timeout(const Duration(seconds: 30));
          await fallback.setLooping(loop);
          try {
            await fallback.setVolume(volume);
          } catch (_) {}
          logging('[factory] fallback ok ${item.key}');
          return fallback;
        } catch (e2) {
          logging('[factory] fallback FAIL ${item.key}: $e2');
          return null;
        }
      }
      return null;
    }
  }

  /// 截短 URL 用于日志显示。
  static String _shortUrl(String url) {
    try {
      final path = Uri.parse(url).pathSegments.last;
      return path.length > 28 ? '…${path.substring(path.length - 28)}' : path;
    } catch (_) {
      return url.length > 36 ? '…${url.substring(url.length - 36)}' : url;
    }
  }

  /// 是否对该 URL 启用本地代理缓存。
  ///
  /// HLS 流（.m3u8）不做整文件缓存；本地文件不经过代理。
  static bool _shouldUseProxy(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('file://')) return false;
    if (lower.contains('.m3u8')) return false;
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /// 确保代理服务器已启动，返回代理 URL。
  static Future<String> _proxyUrl(String originalUrl) async {
    final proxy = VideoCacheProxyServer.instance;
    await proxy.ensureStarted();
    return proxy.proxiedUrl(originalUrl);
  }

  /// 无内部资源需要释放；保留此方法维持接口兼容。
  Future<void> dispose() async {}
}
