import 'dart:io' show File;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:preload_page_view/preload_page_view.dart';
import 'package:video_player/video_player.dart';

import 'models/video_item.dart';
import 'video_player_tile.dart';
import 'services/window_manager.dart';
import 'utils/logging.dart';
import 'enums/eviction_policy.dart';
import 'services/volume_manager.dart';
import 'services/feed_session_manager.dart';
import 'package:extended_image/extended_image.dart';

/// 视频信息流外部控制器
///
/// 提供页面切换与索引查询等外部控制能力，需通过
/// 在 [VideoFeedView] 构造参数中传入 `controller` 完成绑定。
///
/// 使用示例：
/// ```dart
/// final controller = VideoFeedViewController();
/// VideoFeedView(feedId: 'A', items: items, controller: controller);
/// await controller.nextPage();
/// final i = controller.currentIndex();
/// ```
class VideoFeedViewController {
  _VideoFeedViewState? _state;
  bool? _pendingAutoplay;
  void _bind(_VideoFeedViewState s) {
    _state = s;
    if (_pendingAutoplay != null) {
      s._autoplayEnabled = _pendingAutoplay!;
      if (_pendingAutoplay == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await setAutoplay(true);
        });
      }
    }
  }

  /// 切换到下一页
  ///
  /// - 可通过 [duration] 与 [curve] 定制滚动动效
  /// - 当未绑定或数据为空时调用将被忽略
  Future<void> nextPage({
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.ease,
  }) async {
    final s = _state;
    if (s == null || s.widget.items.isEmpty) return;
    try {
      await s._pageController.nextPage(duration: duration, curve: curve);
    } catch (_) {}
  }

  /// 获取当前真实索引（取模后的一致索引）
  ///
  /// - 当启用“近似无限滚动”时，内部使用重复页，但该方法返回
  ///   与 `items` 对应的真实索引范围：`[0, items.length - 1]`
  /// - 未绑定或数据为空时返回 0
  int currentIndex() {
    final s = _state;
    if (s == null || s.widget.items.isEmpty) return 0;
    return s._currentIndex;
  }

  Future<void> pauseThisFeed() async {
    final s = _state;
    if (s == null) return;
    await VideoFeedSessionManager.instance.pauseGroup(s.widget.feedId);
    if (s.mounted) s.setState(() {});
  }

  Future<void> resumeThisFeed() async {
    final s = _state;
    if (s == null) return;
    await VideoFeedSessionManager.instance.resumeGroup(s.widget.feedId);
    if (s.mounted) s.setState(() {});
  }

  bool isPlayingThisFeed() {
    final s = _state;
    if (s == null) return false;
    return VideoFeedSessionManager.instance.isPlaying(s.widget.feedId);
  }

  Future<void> pauseOthers() async {
    final s = _state;
    if (s == null) return;
    await VideoFeedSessionManager.instance.pauseOthers(s.widget.feedId);
    if (s.mounted) s.setState(() {});
  }

  Future<void> pauseAll() async {
    await VideoFeedSessionManager.instance.pauseAll();
    final s = _state;
    if (s != null && s.mounted) s.setState(() {});
  }

  Future<void> resumeAll() async {
    await VideoFeedSessionManager.instance.resumeAll();
    final s = _state;
    if (s != null && s.mounted) s.setState(() {});
  }

  Future<void> releaseThisFeed() async {
    final s = _state;
    if (s == null) return;
    await s._releaseResources();
    _state = null;
  }

  Future<void> setAutoplay(bool enabled) async {
    final s = _state;
    _pendingAutoplay = enabled;
    if (s == null) return;
    s._autoplayEnabled = enabled;
    if (!enabled) return;
    if (s.widget.items.isEmpty || s._currentIndex >= s.widget.items.length)
      return;
    final item = s.widget.items[s._currentIndex];
    await s._getOrCreateController(item);
    final c = s._controllerCache[item.key];
    if (c != null) {
      bool canPlay = false;
      try {
        canPlay =
            c.value.isInitialized && !c.value.hasError && !c.value.isPlaying;
      } catch (_) {
        canPlay = false;
      }
      if (canPlay) {
        await VideoFeedSessionManager.instance
            .playExclusive(s.widget.feedId, c);
        if (s.mounted) s.setState(() {});
      }
    }
  }
}

/// 页面索引变化回调
///
/// 参数为逻辑索引（0..items.length-1）
typedef IndexChanged = void Function(int index);

/// 视频信息流主组件
///
/// - 支持上下滑动翻页、懒加载控制器与自适应窗口保留
/// - 提供“滑到即播”的体验与低内存运行策略
class VideoFeedView extends StatefulWidget {
  const VideoFeedView({
    required this.feedId,
    required this.items,
    this.controller,
    this.initialIndex = 0,
    this.loop = true,
    this.autoplay = true,
    this.preloadAround = 0,
    this.preloadCoverAround = 2,
    this.maxCacheControllers = 2,
    this.settleDelayMs = 60,
    this.infiniteScroll = true,
    this.imageCacheMaxBytes = 32 * 1024 * 1024,
    this.showControllerOnlyOnCurrentPage = true,
    this.onIndexChanged,
    this.aggressiveOnFastScroll = true,
    this.enableLogs = false,
    this.evictionPolicy = EvictionPolicy.lru,
    this.ecoMode = false,
    this.maxControllersEco = 1,
    this.preloadAroundEco = 0,
    this.bizWidgetsBuilder,
    this.viewType = VideoViewType.textureView,
    this.videoPlayerOptions,
    this.emptyBuilder,
    this.playThreshold = 0.8,
    this.allowUserScroll = true,
    super.key,
  });

  /// 数据源列表（每个条目包含视频与封面）
  final List<IVideoItem> items;

  /// 初始展示的逻辑索引
  final int initialIndex;

  /// 是否循环播放当前视频
  final bool loop;

  /// 是否自动播放（初始化完成后立即播放）
  final bool autoplay;

  /// 在当前索引附近预初始化的数量（慢滑场景建议为 1）
  final int
      preloadAround; // how many items to keep initialized around the current index
  /// 在当前索引附近预加载封面图片的数量（避免白屏/闪烁）
  final int preloadCoverAround;

  /// 控制器缓存上限（避免纹理/内存过高）
  final int
      maxCacheControllers; // hard limit on number of cached controllers to avoid OOM
  /// 滚动结束到稳态的延迟（毫秒）；“滑到即播”场景可设为 0
  final int
      settleDelayMs; // delay after scroll end before initializing controllers
  /// 是否启用“近似无限”滚动（通过重复页实现）
  final bool infiniteScroll; // enable virtually infinite vertical scrolling
  /// 全局图片缓存上限（字节），用于控制封面占用
  final int imageCacheMaxBytes; // global ImageCache upper bound (bytes)
  /// 仅在当前页渲染控制器，其他页显示封面以减少纹理内存
  final bool showControllerOnlyOnCurrentPage; // 仅在当前页面上渲染控制器以减少纹理内存
  /// 页索引变化回调
  final IndexChanged? onIndexChanged;

  /// 快滑时是否激进清理，仅保留当前页控制器
  final bool aggressiveOnFastScroll;

  /// 是否开启诊断日志输出
  final bool enableLogs;

  /// 控制器驱逐策略（LRU/FIFO）
  final EvictionPolicy evictionPolicy;

  /// 生态模式：仅保留当前页，禁预加载，以最大限度节省内存
  final bool ecoMode;

  /// 生态模式下的控制器上限（建议 1）
  final int maxControllersEco;

  /// 生态模式下的邻居预加载数量（建议 0）
  final int preloadAroundEco;

  /// 业务叠层构建器：为每个条目构建覆盖在视频之上的组件列表
  final List<Widget> Function(BuildContext context, IVideoItem item, int index)?
      bizWidgetsBuilder;

  final VideoViewType viewType;

  final VideoPlayerOptions? videoPlayerOptions;

  final String feedId;

  /// 外部控制器：用于页面切换与索引查询
  ///
  /// 将一个 [VideoFeedViewController] 传入以获得对组件的外部控制能力。
  /// 绑定由组件在生命周期内自动完成。
  final VideoFeedViewController? controller;

  final WidgetBuilder? emptyBuilder;

  final double playThreshold;
  final bool allowUserScroll;

  @override
  State<VideoFeedView> createState() => _VideoFeedViewState();
}

class _VideoFeedViewState extends State<VideoFeedView>
    with WidgetsBindingObserver {
  final Map<String, VideoPlayerController> _controllerCache = {};
  final List<String> _accessOrder = [];
  final Set<String> _disposingControllers = <String>{};
  final Map<String, Future<VideoPlayerController?>> _creationInFlight = {};

  late final PreloadPageController _pageController;
  int _currentIndex = 0;
  bool _isScrollSettled = true; // true when PageView is idle/settled
  Timer? _settleDebounce;
  int _effectivePreload = 0;
  int _effectiveMaxControllers = 1;
  final Set<String> _preloadedCovers = {};
  Size _viewportSize = const Size(0, 0);
  double _devicePixelRatio = 1.0;
  StreamSubscription<double>? _volumeSub;
  bool _released = false;
  bool _tearingDown = false;
  bool _autoplayEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._bind(this);
    // 限制全局图片缓存占用，缓解封面导致的内存压力
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        widget.imageCacheMaxBytes;
    final int itemLen = widget.items.length;
    final int normalizedInitial =
        itemLen == 0 ? 0 : widget.initialIndex.clamp(0, itemLen - 1);
    final int initialPage = (widget.infiniteScroll && itemLen > 0)
        ? (itemLen * 1000 + normalizedInitial)
        : normalizedInitial;
    _currentIndex = normalizedInitial;
    _pageController = PreloadPageController(initialPage: initialPage);
    _effectivePreload =
        widget.ecoMode ? widget.preloadAroundEco : widget.preloadAround;
    _effectiveMaxControllers =
        widget.ecoMode ? widget.maxControllersEco : widget.maxCacheControllers;
    _autoplayEnabled = widget.autoplay;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _preloadCoversAround(_currentIndex);
      await _manageControllerWindow(_currentIndex);
      // 初始化并根据 autoplay 决定是否播放，同时触发重建
      await _initAndPlayVideo(_currentIndex);
      await VideoFeedSessionManager.instance.pauseOthers(widget.feedId);
      VideoFeedSessionManager.instance.setDelegates(
        widget.feedId,
        clearOthersKeepCurrent: _disposeOthersKeepCurrent,
        restoreWindow: () => _manageControllerWindow(_currentIndex),
      );
    });
    _volumeSub = VolumeManager.instance.stream.listen((vol) async {
      final controllers =
          List<VideoPlayerController>.from(_controllerCache.values);
      for (final c in controllers) {
        try {
          if (c.value.isInitialized) {
            await c.setVolume(vol);
          }
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleDebounce?.cancel();
    _settleDebounce = null;
    VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    VideoFeedSessionManager.instance.removeDelegates(widget.feedId);
    _disposeAllControllers();
    _volumeSub?.cancel();
    super.dispose();
  }

  @override
  void deactivate() {
    VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    super.deactivate();
  }

  Future<void> _releaseResources() async {
    if (_released) return;
    _released = true;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _settleDebounce?.cancel();
    _settleDebounce = null;
    await VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    VideoFeedSessionManager.instance.removeDelegates(widget.feedId);
    await _disposeAllControllers();
    await _volumeSub?.cancel();
  }

  @override
  void didUpdateWidget(VideoFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      widget.controller?._bind(this);
    }
  }

  // 应用生命周期相关逻辑交由业务层处理

  Future<void> _initAndPlayVideo(int index) async {
    if (widget.items.isEmpty || index >= widget.items.length) return;
    final item = widget.items[index];
    await _getOrCreateController(item);
    if (_autoplayEnabled) {
      await _playController(item.key);
    }
    final c = _controllerCache[item.key];
    VideoFeedSessionManager.instance.setCurrent(widget.feedId, c);
    if (mounted) setState(() {});
  }

  void _touchController(String key) {
    _accessOrder
      ..remove(key)
      ..add(key);
  }

  /// 获取或创建控制器
  Future<VideoPlayerController?> _getOrCreateController(IVideoItem item) async {
    final key = item.key;
    if (_controllerCache.containsKey(key)) {
      _touchController(key);
      return _controllerCache[key];
    }

    if (_creationInFlight.containsKey(key)) {
      return await _creationInFlight[key];
    }

    try {
      final int maxSize = widget.maxCacheControllers.clamp(1, 6);
      if (_controllerCache.length >= maxSize) {
        _evictOne(policy: widget.evictionPolicy);
      }

      final future = _createController(item);
      _creationInFlight[key] = future;
      final controller = await future;
      _creationInFlight.remove(key);
      return controller;
    } catch (e) {
      _creationInFlight.remove(key);
      rethrow;
    }
  }

  /// 创建并初始化控制器
  Future<VideoPlayerController?> _createController(IVideoItem item) async {
    final key = item.key;
    try {
      late VideoPlayerController controller;

      if (kIsWeb) {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(item.videoUrl),
          videoPlayerOptions: widget.videoPlayerOptions,
          viewType: widget.viewType,
        );
      } else {
        final cacheManager = DefaultCacheManager();
        final cached = await cacheManager.getFileFromCache(item.videoUrl);
        final File file =
            cached?.file ?? await cacheManager.getSingleFile(item.videoUrl);
        controller = VideoPlayerController.file(
          file,
          videoPlayerOptions: widget.videoPlayerOptions,
          viewType: widget.viewType,
        );
      }

      await controller.initialize();
      await controller.setLooping(widget.loop);
      try {
        await controller.setVolume(VolumeManager.instance.volume);
      } catch (_) {}

      _controllerCache[key] = controller;
      VideoFeedSessionManager.instance.register(widget.feedId, controller);
      _touchController(key);
      _enforceCacheLimit(maxCacheSize: widget.maxCacheControllers.clamp(1, 6));
      if (widget.enableLogs) {
        final s = controller.value.size;
        debugPrint(
            'init ${item.key} size=${s.width}x${s.height} ratio=${controller.value.aspectRatio}');
      }

      return controller;
    } catch (e) {
      // 硬解码路径失败，尝试网络流作为后备（由 ExoPlayer 选择可用的解码方案）
      try {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(item.videoUrl),
          videoPlayerOptions: widget.videoPlayerOptions,
          viewType: widget.viewType,
        );
        await controller.initialize();
        await controller.setLooping(widget.loop);
        try {
          await controller.setVolume(VolumeManager.instance.volume);
        } catch (_) {}
        _controllerCache[key] = controller;
        VideoFeedSessionManager.instance.register(widget.feedId, controller);
        _touchController(key);
        _enforceCacheLimit(
            maxCacheSize: widget.maxCacheControllers.clamp(1, 6));
        if (widget.enableLogs) {
          final s = controller.value.size;
          debugPrint(
              'init(network) ${item.key} size=${s.width}x${s.height} ratio=${controller.value.aspectRatio}');
        }
        return controller;
      } catch (e2) {
        debugPrint('Controller init failed both file and network: $e2');
        return null;
      }
    }
  }

  /// 播放指定控制器
  Future<void> _playController(String key) async {
    final controller = _controllerCache[key];
    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.isPlaying) {
      try {
        await VideoFeedSessionManager.instance
            .playExclusive(widget.feedId, controller);
        if (mounted) setState(() {});
      } catch (e) {
        debugPrint('Error playing video: $e');
      }
    }
  }

  /// 暂停所有控制器
  Future<void> _pauseAllControllers() async {
    final controllers =
        List<VideoPlayerController>.from(_controllerCache.values);
    for (final controller in controllers) {
      try {
        if (controller.value.isInitialized && controller.value.isPlaying) {
          await controller.pause();
        }
      } catch (e) {
        debugPrint('Error pausing video: $e');
      }
    }
  }

  /// 移除并释放指定控制器
  Future<void> _removeController(String key) async {
    if (_disposingControllers.contains(key)) return;
    _disposingControllers.add(key);
    try {
      final controller = _controllerCache[key];
      if (controller != null) {
        _controllerCache.remove(key);
        _accessOrder.remove(key);
        VideoFeedSessionManager.instance.unregister(widget.feedId, controller);
        try {
          if (controller.value.isInitialized && controller.value.isPlaying) {
            await controller.pause();
          }
        } catch (_) {}
        if (mounted && !_tearingDown) {
          setState(() {});
        }
        await Future<void>.delayed(const Duration(milliseconds: 0));
        try {
          await controller.dispose();
        } catch (e) {
          debugPrint('Error disposing controller: $e');
        }
      }
    } finally {
      _disposingControllers.remove(key);
    }
  }

  /// 强制执行缓存上限
  void _enforceCacheLimit({required int maxCacheSize}) {
    while (_controllerCache.length > maxCacheSize && _accessOrder.isNotEmpty) {
      final oldestKey = _accessOrder.first;
      _removeController(oldestKey);
    }
  }

  /// 驱逐一个控制器
  void _evictOne({required EvictionPolicy policy}) {
    if (_controllerCache.isEmpty) return;
    String? evictKey;
    if (policy == EvictionPolicy.fifo) {
      evictKey = _accessOrder.isNotEmpty
          ? _accessOrder.first
          : _controllerCache.keys.first;
    } else {
      evictKey = _accessOrder.isNotEmpty
          ? _accessOrder.first
          : _controllerCache.keys.first;
    }
    _removeController(evictKey);
    if (widget.enableLogs) {
      debugPrint(
          'evict $evictKey policy=$policy size=${_controllerCache.length}');
    }
  }

  /// 释放所有控制器
  Future<void> _disposeAllControllers() async {
    _tearingDown = true;
    final keys = List<String>.from(_controllerCache.keys);
    for (final id in keys) {
      await _removeController(id);
    }
    _controllerCache.clear();
    _accessOrder.clear();
    VideoFeedSessionManager.instance.clearGroup(widget.feedId);
    _tearingDown = false;
  }

  Future<void> _disposeOthersKeepCurrent() async {
    if (widget.items.isEmpty) return;
    final currentKey = widget.items[_currentIndex].key;
    final idsToDispose = List<String>.from(_controllerCache.keys);
    for (final k in idsToDispose) {
      if (k != currentKey) {
        await _removeController(k);
      }
    }
  }

  /// 管理控制器窗口
  Future<void> _manageControllerWindow(int currentIndex) async {
    await manageControllerWindow(
      items: widget.items,
      currentIndex: currentIndex,
      maxCacheControllers: widget.maxCacheControllers,
      controllerCache: _controllerCache,
      removeController: _removeController,
      getOrCreateController: _getOrCreateController,
      enableLogs: widget.enableLogs,
    );
  }

  /// 处理页面变化
  Future<void> _handlePageChange(int newIndex) async {
    if (widget.items.isEmpty) return;
    final previousIndex = _currentIndex;
    final normalized = newIndex % widget.items.length;
    _currentIndex = normalized;
    final isFastScroll = (newIndex - previousIndex).abs() > 1;
    try {
      final currentItem = widget.items[_currentIndex];
      final currentKey = currentItem.key;

      final bool useEco =
          widget.ecoMode || (widget.aggressiveOnFastScroll && isFastScroll);
      _effectivePreload =
          useEco ? widget.preloadAroundEco : widget.preloadAround;
      _effectiveMaxControllers =
          useEco ? widget.maxControllersEco : widget.maxCacheControllers;

      await _preloadCoversAround(_currentIndex);

      // 仅当前播放：暂停非当前控制器
      for (final entry in _controllerCache.entries) {
        if (entry.key == currentKey) continue;
        try {
          if (entry.value.value.isInitialized && entry.value.value.isPlaying) {
            await entry.value.pause();
          }
        } catch (_) {}
      }

      if (widget.aggressiveOnFastScroll && isFastScroll) {
        final idsToDispose = List<String>.from(_controllerCache.keys);
        for (final k in idsToDispose) {
          if (k != currentKey) await _removeController(k);
        }
      } else {
        await manageControllerWindow(
          items: widget.items,
          currentIndex: _currentIndex,
          maxCacheControllers: _effectiveMaxControllers,
          controllerCache: _controllerCache,
          removeController: _removeController,
          getOrCreateController: _getOrCreateController,
          enableLogs: widget.enableLogs,
        );
      }

      await _getOrCreateController(currentItem);
      if (_autoplayEnabled) await _playController(currentKey);
      if (mounted) setState(() {});
      widget.onIndexChanged?.call(_currentIndex);
      logIf(widget.enableLogs,
          'page=$newIndex fast=$isFastScroll eco=$useEco effectivePreload=$_effectivePreload effectiveMax=$_effectiveMaxControllers active=${_controllerCache.length}');
    } catch (e) {
      debugPrint('Error handling page change: $e');
    }
  }

  /// 应用稳态页面逻辑
  Future<void> _applyStablePage() async {
    if (widget.items.isEmpty || _currentIndex >= widget.items.length) return;
    await _manageControllerWindow(_currentIndex);
    await _initAndPlayVideo(_currentIndex);
    final currentItem = widget.items[_currentIndex];
    final c = _controllerCache[currentItem.key];
    VideoFeedSessionManager.instance.setCurrent(widget.feedId, c);
    widget.onIndexChanged?.call(_currentIndex);
  }

  /// 监听滚动通知
  bool _onScrollNotification(ScrollNotification n) {
    // 标记滚动状态：滑动中 -> 未稳态；滚动结束 -> 稳态 并延迟应用页面逻辑
    if (n is ScrollStartNotification ||
        n is ScrollUpdateNotification ||
        (n is UserScrollNotification && n.direction != ScrollDirection.idle)) {
      if (_isScrollSettled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _isScrollSettled = false;
        });
      }
      _settleDebounce?.cancel();
      if (n is ScrollUpdateNotification) {
        final page = _pageController.page;
        final len = widget.items.length;
        if (page != null && len > 0) {
          final nearest = page.round();
          final frac = 1.0 - (page - nearest).abs();
          final threshold = widget.playThreshold.clamp(0.5, 1.0);
          if (frac >= threshold) {
            final normalized = nearest % len;
            if (_currentIndex != normalized) {
              _currentIndex = normalized;
              _applyStablePage();
            }
          }
        }
      }
    } else if (n is ScrollEndNotification ||
        (n is UserScrollNotification && n.direction == ScrollDirection.idle)) {
      _settleDebounce?.cancel();
      _settleDebounce =
          Timer(Duration(milliseconds: widget.settleDelayMs), () async {
        if (mounted) setState(() => _isScrollSettled = true);
        await _applyStablePage();
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return widget.emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size viewportSize = constraints.biggest;
        _viewportSize = viewportSize;
        _devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: PreloadPageView.builder(
            scrollDirection: Axis.vertical,
            controller: _pageController,
            itemCount: widget.infiniteScroll
                ? (widget.items.isEmpty ? 0 : 1000000)
                : widget.items.length,
            physics: widget.allowUserScroll
                ? const AlwaysScrollableScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            preloadPagesCount: _effectivePreload,
            onPageChanged: _handlePageChange,
            itemBuilder: (context, index) {
              final logicalIndex =
                  widget.items.isEmpty ? 0 : index % widget.items.length;
              final item = widget.items[logicalIndex];
              final controller = _controllerCache[item.key];
              // 滑动中只显示封面；稳态时仅当前页渲染控制器（可配置）。正在释放的控制器也传递 null。
              final isCurrent = logicalIndex == _currentIndex;
              final shouldShowController =
                  (widget.showControllerOnlyOnCurrentPage ? isCurrent : true) &&
                      !_disposingControllers.contains(item.key);
              final safeController = shouldShowController ? controller : null;
              return RepaintBoundary(
                key: ValueKey('${item.key}#$index'),
                child: VideoPlayerTile(
                  controller: safeController,
                  videoId: item.key,
                  coverUrl: item.coverUrl,
                  viewportSize: viewportSize,
                  groupId: widget.feedId,
                  isCurrent: isCurrent,
                  bizWidgets: widget.bizWidgetsBuilder
                      ?.call(context, item, logicalIndex),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 预加载当前索引附近的封面图片
  Future<void> _preloadCoversAround(int centerIndex) async {
    if (widget.items.isEmpty) return;
    final int n = widget.preloadCoverAround.clamp(0, widget.items.length);
    if (n == 0) return;
    int wrap(int i) =>
        (i % widget.items.length + widget.items.length) % widget.items.length;
    final futures = <Future<void>>[];
    final int cacheWidth = (_viewportSize.width * _devicePixelRatio).round();
    final int cacheHeight = (_viewportSize.height * _devicePixelRatio).round();
    for (int i = -n; i <= n; i++) {
      final idx = wrap(centerIndex + i);
      final item = widget.items[idx];
      if (_preloadedCovers.contains(item.coverUrl)) continue;
      final provider = ResizeImage(
        ExtendedNetworkImageProvider(item.coverUrl, cache: true),
        width: cacheWidth,
        height: cacheHeight,
      );
      futures.add(precacheImage(provider, context).then((_) {
        _preloadedCovers.add(item.coverUrl);
      }).catchError((_) {}));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }
}
