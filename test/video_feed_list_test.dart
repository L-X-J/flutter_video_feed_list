import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_feed_list/flutter_video_feed_list.dart';
import 'package:flutter_video_feed_list/src/services/window_manager.dart';
import 'package:flutter_video_feed_list/src/video_layout.dart';

/// `resolveVideoLayout` 的比例决策测试。
///
/// 这些测试覆盖了当前短视频流最关键的 5 类素材比例，确保自适应模式始终遵守
/// “普通素材完整展示优先、9:16 手机竖版保留底部业务区”的规则，同时验证默认
/// `cover` 模式没有回归。
void main() {
  group('controllerKeysForWindow', () {
    final items = List<DefaultVideoItem>.generate(
      4,
      (index) => DefaultVideoItem(
        id: 'v$index',
        videoUrl: 'https://example.com/v$index.mp4',
        coverUrl: 'https://example.com/v$index.jpg',
      ),
    );

    test('max 为 1 时只保留当前页', () {
      final keys = controllerKeysForWindow(
        items: items,
        currentIndex: 2,
        maxCacheControllers: 1,
      );

      expect(keys, <String>{'v2'});
    });

    test('优先保留当前页和最近邻居', () {
      final keys = controllerKeysForWindow(
        items: items,
        currentIndex: 1,
        maxCacheControllers: 2,
      );

      expect(keys, <String>{'v1', 'v0'});
    });

    test('边界页按现有窗口策略环绕保留邻居', () {
      final keys = controllerKeysForWindow(
        items: items,
        currentIndex: 0,
        maxCacheControllers: 2,
      );

      expect(keys, <String>{'v0', 'v3'});
    });
  });

  group('resolveVideoLayout', () {
    test('默认 cover 模式保持旧行为', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.cover,
        viewportSize: const Size(390, 844),
        videoSize: const Size(720, 1280),
      );

      expect(decision.videoFit, BoxFit.cover);
      expect(decision.coverFit, BoxFit.fitHeight);
      expect(decision.alignment, Alignment.center);
    });

    test('横屏视频在 adaptive 模式下完整展示并居中', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(390, 844),
        videoSize: const Size(1920, 1080),
      );

      expect(decision.videoFit, BoxFit.contain);
      expect(decision.coverFit, BoxFit.contain);
      expect(decision.alignment, Alignment.center);
    });

    test('9比16 手机竖版视频顶部贴顶并为底部业务区留白', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(390, 844),
        videoSize: const Size(1080, 1920),
      );

      expect(decision.videoFit, BoxFit.cover);
      expect(decision.coverFit, BoxFit.cover);
      expect(decision.alignment, Alignment.topCenter);
      expect(decision.mediaInsets.bottom, closeTo(97.93, 0.01));
    });

    test('9比16 视频在 iPad 视口中回退为完整展示居中', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(820, 1180),
        videoSize: const Size(1080, 1920),
      );

      expect(decision.videoFit, BoxFit.contain);
      expect(decision.coverFit, BoxFit.contain);
      expect(decision.alignment, Alignment.center);
    });

    test('接近 3比4 的竖版视频回退为完整展示居中', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(390, 844),
        videoSize: const Size(720, 956),
      );

      expect(decision.videoFit, BoxFit.contain);
      expect(decision.coverFit, BoxFit.contain);
      expect(decision.alignment, Alignment.center);
      expect(decision.mediaInsets, EdgeInsets.zero);
    });

    test('正方形视频在 adaptive 模式下完整展示并居中', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(390, 844),
        videoSize: const Size(1080, 1080),
      );

      expect(decision.videoFit, BoxFit.contain);
      expect(decision.coverFit, BoxFit.contain);
      expect(decision.alignment, Alignment.center);
    });

    test('3比4 视频在 adaptive 模式下完整展示并居中', () {
      final decision = resolveVideoLayout(
        displayMode: VideoDisplayMode.adaptive,
        viewportSize: const Size(390, 844),
        videoSize: const Size(960, 1280),
      );

      expect(decision.videoFit, BoxFit.contain);
      expect(decision.coverFit, BoxFit.contain);
      expect(decision.alignment, Alignment.center);
    });
  });
}
