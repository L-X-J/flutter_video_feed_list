import 'dart:async';
import 'dart:io' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';

/// 控制器工厂：负责按“边播边缓存”的策略创建并初始化 VideoPlayerController
///
/// - 命中缓存时：使用本地文件播放以获得更快启动
/// - 未命中缓存时：立即使用网络播放，并在后台启动缓存下载（打印速率与进度）
/// - HLS/流媒体（`.m3u8`）不执行整文件缓存，仅网络播放
/// - 遇到初始化失败时支持切换到 `platformView` 兜底
class VideoControllerFactory {
  VideoControllerFactory({required bool enableLogs}) : _enableLogs = enableLogs;

  final bool _enableLogs;
  final Map<String, StreamSubscription<FileResponse>> _subs = {};
  final Map<String, int> _lastBytes = {};
  final Map<String, DateTime> _lastAt = {};

  /// 创建并初始化控制器
  ///
  /// 参数:
  /// - [item] 视频条目，需包含 `videoUrl` 与唯一 `key`
  /// - [viewType] 视图类型（TextureView/PlatformView）
  /// - [loop] 是否循环播放
  /// - [volume] 初始音量
  ///
  /// 返回:
  /// - 成功时返回已初始化的 `VideoPlayerController`；失败返回 `null`
  Future<VideoPlayerController?> createAndInit(
    IVideoItem item, {
    required VideoViewType viewType,
    required bool loop,
    required double volume,
  }) async {
    final cacheManager = DefaultCacheManager();
    final isHls = item.videoUrl.toLowerCase().contains('.m3u8');
    final cached = await cacheManager.getFileFromCache(item.videoUrl);
    if (cached?.file != null) {
      final File file = cached!.file;
      final controller = VideoPlayerController.file(
        file,
        viewType: viewType,
      );
      await controller.initialize();
      await controller.setLooping(loop);
      try {
        await controller.setVolume(volume);
      } catch (_) {}
      if (_enableLogs) {
        final s = controller.value.size;
        // ignore: avoid_print
        print(
            'init(cache) ${item.key} size=${s.width}x${s.height} ratio=${controller.value.aspectRatio} type=$viewType');
      }
      return controller;
    }

    try {
      // 立即网络播放
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(item.videoUrl),
        viewType: viewType,
      );
      await controller.initialize();
      await controller.setLooping(loop);
      try {
        await controller.setVolume(volume);
      } catch (_) {}
      if (_enableLogs) {
        final s = controller.value.size;
        // ignore: avoid_print
        print(
            'init(network-stream) ${item.key} size=${s.width}x${s.height} ratio=${controller.value.aspectRatio} type=$viewType');
      }
      // 后台缓存下载（非 HLS）
      if (!isHls && !_subs.containsKey(item.key)) {
        final stream =
            cacheManager.getFileStream(item.videoUrl, withProgress: true);
        final sub = stream.listen((resp) {
          if (resp is DownloadProgress) {
            final now = DateTime.now();
            final lastBytes = _lastBytes[item.key];
            final lastAt = _lastAt[item.key];
            if (lastBytes != null && lastAt != null) {
              final deltaBytes = resp.downloaded - lastBytes;
              final dtMs = now.difference(lastAt).inMilliseconds;
              if (dtMs > 0 && _enableLogs) {
                final speed = deltaBytes / (dtMs / 1000.0);
                final total = resp.totalSize ?? 0;
                final percent = total > 0
                    ? ((resp.downloaded * 100.0) / total).toStringAsFixed(1)
                    : '?.?';
                // ignore: avoid_print
                print('cache ${item.key} $percent% ${_fmtBytes(speed)}/s');
              }
            }
            _lastBytes[item.key] = resp.downloaded;
            _lastAt[item.key] = now;
          } else if (resp is FileInfo) {
            if (_enableLogs) {
              try {
                final sz = resp.file.lengthSync();
                // ignore: avoid_print
                print('cache ${item.key} done ${_fmtBytes(sz)}');
              } catch (_) {
                // ignore: avoid_print
                print('cache ${item.key} done');
              }
            }
          }
        }, onError: (_) {}, onDone: () {
          _cleanup(item.key);
        }, cancelOnError: true);
        _subs[item.key] = sub;
      }
      return controller;
    } catch (e) {
      // 尝试切换到 platformView 兜底
      if (viewType != VideoViewType.platformView) {
        try {
          final controller = VideoPlayerController.networkUrl(
            Uri.parse(item.videoUrl),
            viewType: VideoViewType.platformView,
          );
          await controller.initialize();
          await controller.setLooping(loop);
          try {
            await controller.setVolume(volume);
          } catch (_) {}
          if (_enableLogs) {
            final s = controller.value.size;
            // ignore: avoid_print
            print(
                'init(platformView) ${item.key} size=${s.width}x${s.height} ratio=${controller.value.aspectRatio}');
          }
          return controller;
        } catch (e3) {
          // ignore: avoid_print
          print('Controller init failed all fallbacks: $e3');
          return null;
        }
      }
      // ignore: avoid_print
      print('Controller init failed in network stream: $e');
      return null;
    }
  }

  /// 释放并清理内部资源（取消下载订阅）
  Future<void> dispose() async {
    final subs = List<StreamSubscription<FileResponse>>.from(_subs.values);
    for (final s in subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    _lastBytes.clear();
    _lastAt.clear();
  }

  void _cleanup(String key) {
    _subs.remove(key)?.cancel();
    _lastBytes.remove(key);
    _lastAt.remove(key);
  }

  String _fmtBytes(num b) {
    final units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024.0 && i < units.length - 1) {
      v /= 1024.0;
      i++;
    }
    final fixed = v < 10 ? 2 : 1;
    return '${v.toStringAsFixed(fixed)} ${units[i]}';
  }
}
