import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:preload_page_view/preload_page_view.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'enums/eviction_policy.dart';
import 'enums/video_display_mode.dart';
import 'models/video_item.dart';
import 'services/controller_factory.dart';
import 'services/feed_session_manager.dart';
import 'services/volume_manager.dart';
import 'services/window_manager.dart';
import 'utils/logging.dart';
import 'video_player_tile.dart';

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
    await s._pauseFeedForReason(VideoPlaybackStopReason.manualPause);
    // ignore: invalid_use_of_protected_member
    if (s.mounted) s.setState(() {});
  }

  /// 按指定原因暂停当前 feed。
  ///
  /// 业务页面在生命周期切换、路由覆盖等自动暂停场景应显式传入非手动原因，
  /// 避免外层把系统暂停误判为用户手势暂停。
  Future<void> pauseThisFeedForReason(VideoPlaybackStopReason reason) async {
    final s = _state;
    if (s == null) return;
    await s._pauseFeedForReason(reason);
    // ignore: invalid_use_of_protected_member
    if (s.mounted) s.setState(() {});
  }

  Future<void> resumeThisFeed() async {
    final s = _state;
    if (s == null) return;
    await s._resumeCurrentIfAllowed();
    // ignore: invalid_use_of_protected_member
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
    // ignore: invalid_use_of_protected_member
    if (s.mounted) s.setState(() {});
  }

  Future<void> pauseAll() async {
    await VideoFeedSessionManager.instance.pauseAll();
    final s = _state;
    // ignore: invalid_use_of_protected_member
    if (s != null && s.mounted) s.setState(() {});
  }

  Future<void> resumeAll() async {
    final s = _state;
    if (s != null) {
      await s._resumeCurrentIfAllowed();
      // ignore: invalid_use_of_protected_member
      if (s.mounted) s.setState(() {});
      return;
    }
    await VideoFeedSessionManager.instance.resumeAll();
    // ignore: invalid_use_of_protected_member
    if (s != null && s.mounted) s.setState(() {});
  }

  Future<void> releaseThisFeed() async {
    final s = _state;
    if (s == null) return;
    await s._releaseResources();
    _state = null;
  }

  /// 立即结算当前播放段。
  ///
  /// 该方法适合在业务页面即将主动切换上下文时兜底调用，避免最后一段播放时长因为
  /// 页面生命周期切换过快而来不及上报。
  Future<void> finishCurrentPlaybackSegment({
    VideoPlaybackStopReason reason = VideoPlaybackStopReason.manualPause,
  }) async {
    final s = _state;
    if (s == null) return;
    await s._flushActivePlaybackSegment(reason);
  }

  Future<void> setAutoplay(bool enabled) async {
    final s = _state;
    _pendingAutoplay = enabled;
    if (s == null) return;
    s._autoplayEnabled = enabled;
    if (!enabled) {
      await s._pauseFeedForReason(VideoPlaybackStopReason.autoplayDisabled);
      return;
    }
    await s._resumeCurrentIfAllowed();
  }
}

/// 页面索引变化回调
///
/// 参数为逻辑索引（0..items.length-1）
typedef IndexChanged = void Function(int index);

/// 播放状态。
enum VideoPlaybackState {
  started,
  paused,
}

/// 播放状态变化原因。
enum VideoPlaybackStateChangeReason {
  playbackStarted,
  manualResume,
  pageChanged,
  invisible,
  appLifecycle,
  manualPause,
  autoplayDisabled,
  controllerRemoved,
  released,
  disposed,
}

/// 播放段结束原因。
enum VideoPlaybackStopReason {
  pageChanged,
  invisible,
  appLifecycle,
  manualPause,
  autoplayDisabled,
  controllerRemoved,
  released,
  disposed,
}

/// 单次播放状态变化事件。
///
/// 播放器会在“真正开始播放”和“当前播放段被暂停/打断”两个时机抛出事件，
/// 业务层可据此记录播放状态、调试日志或做额外埋点。
class VideoPlaybackStateEvent {
  const VideoPlaybackStateEvent({
    required this.item,
    required this.index,
    required this.state,
    required this.reason,
  });

  final IVideoItem item;
  final int index;
  final VideoPlaybackState state;
  final VideoPlaybackStateChangeReason reason;
}

/// 单次播放段信息。
///
/// 只有在当前播放段累计秒数达到 1 秒时，播放器才会向外抛出该对象，避免业务层
/// 收到大量不足 1 秒的碎片事件。
class VideoPlaybackSegment {
  const VideoPlaybackSegment({
    required this.item,
    required this.index,
    required this.playedDuration,
    required this.stopReason,
  });

  final IVideoItem item;
  final int index;
  final Duration playedDuration;
  final VideoPlaybackStopReason stopReason;
}

/// 单次播放进度事件。
///
/// 该事件只暴露业务侧需要的只读播放状态，避免页面直接依赖播放器内部控制器。
class VideoPlaybackProgressEvent {
  const VideoPlaybackProgressEvent({
    required this.item,
    required this.index,
    required this.position,
    required this.duration,
    required this.isPlaying,
  });

  final IVideoItem item;
  final int index;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
}

/// 视频信息流主组件
///
/// - 支持上下滑动翻页、懒加载控制器与自适应窗口保留
/// - 提供“滑到即播”的体验与低内存运行策略
class VideoFeedView extends StatefulWidget {
  VideoFeedView({
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
    this.onPlaybackStateChanged,
    this.onPlaybackSegment,
    this.onPlaybackProgress,
    this.aggressiveOnFastScroll = true,
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
    this.coverFit,
    this.videoDisplayMode = VideoDisplayMode.cover,
    LogFunction? logF,
    super.key,
  }) {
    if (logF != null) {
      logFunction = logF;
    }
  }

  /// 数据源列表（每个条目包含视频与封面）
  final List<IVideoItem> items;

  /// 初始展示的逻辑索引
  final int initialIndex;

  final BoxFit? coverFit;

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

  /// 播放状态变化回调。
  ///
  /// 该回调用于通知业务层某条视频已经真正进入播放态，或因切页/离场/暂停而退出
  /// 当前播放段。
  final FutureOr<void> Function(VideoPlaybackStateEvent event)?
      onPlaybackStateChanged;

  /// 当前播放段结算回调。
  ///
  /// 只有单段累计播放时长达到 1 秒才会触发，适合用于浏览量上报等按秒结算的业务。
  final FutureOr<void> Function(VideoPlaybackSegment segment)?
      onPlaybackSegment;

  /// 当前播放进度回调。
  ///
  /// 回调仅针对当前页控制器，并做轻量节流，适合业务层根据时间线触发外部联动。
  final FutureOr<void> Function(VideoPlaybackProgressEvent event)?
      onPlaybackProgress;

  /// 快滑时是否激进清理，仅保留当前页控制器
  final bool aggressiveOnFastScroll;

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

  /// 视频在当前视口中的展示模式。
  ///
  /// 默认值保持为 [VideoDisplayMode.cover]，用于兼容既有页面的满屏裁切表现；
  /// 当业务侧需要“尽量完整展示”，同时希望 9:16 手机竖版素材顶部贴顶、底部为
  /// 业务信息预留稳定空间时，可以显式传入 `contain` 或 `adaptive`。
  final VideoDisplayMode videoDisplayMode;

  @override
  State<VideoFeedView> createState() => _VideoFeedViewState();
}

class _VideoFeedViewState extends State<VideoFeedView>
    with WidgetsBindingObserver {
  final Map<String, VideoPlayerController> _controllerCache = {};
  final List<String> _accessOrder = [];
  final Set<String> _disposingControllers = <String>{};
  final Map<String, Future<VideoPlayerController?>> _creationInFlight = {};
  final Map<String, VoidCallback> _controllerProgressListeners =
      <String, VoidCallback>{};
  late final VideoControllerFactory _controllerFactory;

  late final PreloadPageController _pageController;
  int _currentIndex = 0;
  int _lastPageViewIndex = 0;
  bool _isScrollSettled = true; // true when PageView is idle/settled
  Timer? _settleDebounce;
  int _stableApplyGeneration = 0;
  int? _scheduledStablePageIndex;
  int? _pendingStablePageIndex;
  bool _isApplyingStablePage = false;
  int _effectivePreload = 0;
  int _effectiveMaxControllers = 1;
  final Set<String> _preloadedCovers = {};
  Size _viewportSize = const Size(0, 0);
  double _devicePixelRatio = 1.0;
  StreamSubscription<double>? _volumeSub;
  bool _released = false;
  bool _tearingDown = false;
  bool _autoplayEnabled = true;
  bool _isHuawei = false;
  bool _deviceCheckDone = false;
  bool _isAppForeground = true;
  double _visibleFraction = 1.0;
  String? _activePlaybackKey;
  int? _activePlaybackIndex;
  DateTime? _activePlaybackStartedAt;
  String? _lastProgressKey;
  DateTime? _lastProgressNotifiedAt;

  /// 当前 feed 是否允许真正发起播放。
  ///
  /// 这里把自动播放开关、App 前后台和组件实际可见性统一纳入判断，
  /// 避免异步初始化、缓冲完成或外部 resume 在页面不可见时把视频重新播起来。
  bool get _canStartPlayback =>
      _autoplayEnabled &&
      _isAppForeground &&
      _visibleFraction > 0.01 &&
      !_released &&
      !_tearingDown;

  /// 当前策略下允许保留的控制器上限。
  int get _resolvedMaxControllers => _effectiveMaxControllers.clamp(1, 6);

  /// 将 PageView 的物理页索引归一化为业务数据索引。
  int _normalizeIndex(int index) {
    if (widget.items.isEmpty) return 0;
    return index % widget.items.length;
  }

  /// 滚动中的稳态任务使用最小防抖，避免短时间跨过多个页面时为中间页创建控制器。
  Duration _stableApplyDelay({required bool duringScroll}) {
    final configuredMs = widget.settleDelayMs < 0 ? 0 : widget.settleDelayMs;
    if (!duringScroll) {
      return Duration(milliseconds: configuredMs);
    }
    const minDuringScrollMs = 80;
    return Duration(
      milliseconds:
          configuredMs < minDuringScrollMs ? minDuringScrollMs : configuredMs,
    );
  }

  /// 获取 PageView 当前最接近的业务索引。
  int _nearestLogicalIndex() {
    if (widget.items.isEmpty) return 0;
    try {
      final page = _pageController.page;
      if (page == null) return _currentIndex;
      return _normalizeIndex(page.round());
    } catch (_) {
      return _currentIndex;
    }
  }

  /// 判断指定 key 是否仍是当前页。
  bool _isCurrentKey(String key) {
    if (widget.items.isEmpty || _currentIndex >= widget.items.length) {
      return false;
    }
    return widget.items[_currentIndex].key == key;
  }

  /// 计算某个目标页在当前策略下应保留的 controller key 集合。
  Set<String> _controllerKeysForTargetWindow(int targetIndex) {
    return controllerKeysForWindow(
      items: widget.items,
      currentIndex: _normalizeIndex(targetIndex),
      maxCacheControllers: _resolvedMaxControllers,
    );
  }

  /// 判断异步创建完成的控制器是否仍处在目标窗口中。
  bool _shouldKeepControllerKey(String key, {int? targetIndex}) {
    if (widget.items.isEmpty || _released || _tearingDown) {
      return false;
    }
    final keysToKeep = _controllerKeysForTargetWindow(
      targetIndex ?? _currentIndex,
    );
    return keysToKeep.contains(key);
  }

  /// 判断某个稳态任务是否仍是最新任务。
  bool _isStableApplyActive(int? generation, int? targetIndex) {
    if (!mounted || _released || _tearingDown || widget.items.isEmpty) {
      return false;
    }
    if (generation != null && generation != _stableApplyGeneration) {
      return false;
    }
    if (targetIndex != null && _normalizeIndex(targetIndex) != _currentIndex) {
      return false;
    }
    return true;
  }

  /// 根据快滑状态刷新实际窗口策略。
  bool _updateEffectiveWindowForScroll({required bool isFastScroll}) {
    final bool useEco =
        widget.ecoMode || (widget.aggressiveOnFastScroll && isFastScroll);
    _effectivePreload = useEco ? widget.preloadAroundEco : widget.preloadAround;
    _effectiveMaxControllers =
        useEco ? widget.maxControllersEco : widget.maxCacheControllers;
    return useEco;
  }

  /// 判断异步 page change 回调是否仍对应最新物理页。
  bool _isLatestPageChange(int pageIndex, {int? normalizedIndex}) {
    if (!mounted || _released || _tearingDown) {
      return false;
    }
    if (_lastPageViewIndex != pageIndex) {
      return false;
    }
    if (normalizedIndex != null && _currentIndex != normalizedIndex) {
      return false;
    }
    return true;
  }

  /// 取消尚未执行的稳态任务，并使正在执行的旧任务失效。
  void _invalidateStablePageApply() {
    _settleDebounce?.cancel();
    _settleDebounce = null;
    _scheduledStablePageIndex = null;
    _pendingStablePageIndex = null;
    _stableApplyGeneration++;
  }

  /// 调度一次稳态页面应用。
  ///
  /// 只记录最新目标页，真正的控制器窗口管理由 [_drainStablePageApply] 串行执行。
  void _scheduleStablePageApply(
    int targetIndex, {
    required bool duringScroll,
    required bool markSettled,
  }) {
    if (widget.items.isEmpty || _released || _tearingDown) {
      return;
    }
    _scheduledStablePageIndex = _normalizeIndex(targetIndex);
    _pendingStablePageIndex = null;
    _stableApplyGeneration++;
    _settleDebounce?.cancel();

    final generation = _stableApplyGeneration;
    _settleDebounce = Timer(_stableApplyDelay(duringScroll: duringScroll), () {
      if (!_isStableApplyActive(generation, null)) {
        return;
      }
      final scheduledIndex = _scheduledStablePageIndex;
      if (scheduledIndex == null) {
        return;
      }
      _scheduledStablePageIndex = null;
      _pendingStablePageIndex = scheduledIndex;
      if (markSettled && mounted) {
        setState(() => _isScrollSettled = true);
      }
      unawaited(_drainStablePageApply());
    });
  }

  /// 串行执行稳态任务，避免多个页面同时初始化/播放控制器。
  Future<void> _drainStablePageApply() async {
    if (_isApplyingStablePage) {
      return;
    }
    _isApplyingStablePage = true;
    try {
      while (
          _isStableApplyActive(null, null) && _pendingStablePageIndex != null) {
        final targetIndex = _pendingStablePageIndex!;
        _pendingStablePageIndex = null;
        final generation = _stableApplyGeneration;
        await _applyStablePage(targetIndex, generation);
      }
    } finally {
      _isApplyingStablePage = false;
      if (_isStableApplyActive(null, null) && _pendingStablePageIndex != null) {
        unawaited(_drainStablePageApply());
      }
    }
  }

  /// 切换当前业务索引，并在索引真正变化时结算上一段播放。
  Future<void> _setCurrentIndex(
    int index, {
    required VideoPlaybackStopReason reason,
  }) async {
    if (widget.items.isEmpty) return;
    final normalized = _normalizeIndex(index);
    if (normalized == _currentIndex) return;
    await _flushActivePlaybackSegment(reason);
    _currentIndex = normalized;
  }

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
    _lastPageViewIndex = initialPage;
    _pageController = PreloadPageController(initialPage: initialPage);
    _effectivePreload =
        widget.ecoMode ? widget.preloadAroundEco : widget.preloadAround;
    _effectiveMaxControllers =
        widget.ecoMode ? widget.maxControllersEco : widget.maxCacheControllers;
    _autoplayEnabled = widget.autoplay;
    _controllerFactory = VideoControllerFactory();

    // Start device check
    _checkDevice().then((_) {
      if (mounted) {
        // Check if we need to re-initialize the current controller if it was already created with wrong type?
        // Actually, _initAndPlayVideo runs in postFrameCallback, which might be after this check returns
        // if _checkDevice is super fast, but usually _checkDevice is async.
        // We'll handle the logic in _createController to await this if needed or just let the fallback handle it if check isn't done.
        // But ideally we want to know before first creation.
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final generation = _stableApplyGeneration;
      await _preloadCoversAround(_currentIndex);
      await _manageControllerWindow(_currentIndex, generation: generation);
      // 初始化并根据 autoplay 决定是否播放，同时触发重建
      await _initAndPlayVideo(_currentIndex, generation: generation);
      await VideoFeedSessionManager.instance.pauseOthers(widget.feedId);
      VideoFeedSessionManager.instance.setDelegates(
        widget.feedId,
        clearOthersKeepCurrent: _disposeOthersKeepCurrent,
        restoreWindow: () => _manageControllerWindow(_currentIndex),
      );
    });
    _volumeSub = VolumeManager.instance.stream.listen((vol) async {
      final controllers = List<VideoPlayerController>.from(
        _controllerCache.values,
      );
      for (final c in controllers) {
        try {
          if (c.value.isInitialized) {
            await c.setVolume(vol);
          }
        } catch (_) {}
      }
    });
  }

  Future<void> _checkDevice() async {
    if (!Platform.isAndroid) {
      _deviceCheckDone = true;
      return;
    }
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final manufacturer = androidInfo.manufacturer.toLowerCase();
      final brand = androidInfo.brand.toLowerCase();
      if (manufacturer.contains('huawei') || brand.contains('huawei')) {
        _isHuawei = true;
      }
    } catch (e) {
      logging('Device info check failed: $e');
    } finally {
      _deviceCheckDone = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _invalidateStablePageApply();
    unawaited(_flushActivePlaybackSegment(VideoPlaybackStopReason.disposed));
    VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    VideoFeedSessionManager.instance.removeDelegates(widget.feedId);
    _disposeAllControllers();
    _volumeSub?.cancel();
    super.dispose();
  }

  @override
  void deactivate() {
    unawaited(_flushActivePlaybackSegment(VideoPlaybackStopReason.invisible));
    VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    super.deactivate();
  }

  Future<void> _releaseResources() async {
    if (_released) return;
    _released = true;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _invalidateStablePageApply();
    await _flushActivePlaybackSegment(VideoPlaybackStopReason.released);
    await VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    VideoFeedSessionManager.instance.removeDelegates(widget.feedId);
    await _disposeAllControllers();
    await _volumeSub?.cancel();
    await _controllerFactory.dispose();
  }

  @override
  void didUpdateWidget(VideoFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      widget.controller?._bind(this);
    }
  }

  @override

  /// 当 App 前后台切换时，自动同步当前 feed 的播放许可。
  ///
  /// 只要应用不在前台，就立即暂停当前 feed；
  /// 回到前台后再根据组件可见性决定是否恢复当前条目。
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppForeground = state == AppLifecycleState.resumed;
    if (_canStartPlayback) {
      unawaited(_resumeCurrentIfAllowed());
    } else {
      unawaited(_pauseFeedForReason(VideoPlaybackStopReason.appLifecycle));
    }
  }

  /// 处理 feed 自身可见性变化。
  ///
  /// 当页面被新路由盖住时，`visibleFraction` 会降到接近 0，此时必须立刻暂停；
  /// 页面重新回到前台后，再由当前索引恢复应播放的控制器。
  void _handleVisibilityChanged(VisibilityInfo info) {
    final bool wasVisible = _visibleFraction > 0.01;
    _visibleFraction = info.visibleFraction;
    final bool isVisible = _visibleFraction > 0.01;
    if (wasVisible == isVisible) {
      return;
    }
    if (_canStartPlayback) {
      unawaited(_resumeCurrentIfAllowed());
    } else {
      unawaited(_pauseFeedForReason(VideoPlaybackStopReason.invisible));
    }
  }

  /// 发送播放状态变化事件。
  void _notifyPlaybackState({
    required IVideoItem item,
    required int index,
    required VideoPlaybackState state,
    required VideoPlaybackStateChangeReason reason,
  }) {
    final callback = widget.onPlaybackStateChanged;
    if (callback == null) {
      return;
    }
    callback(
      VideoPlaybackStateEvent(
        item: item,
        index: index,
        state: state,
        reason: reason,
      ),
    );
  }

  /// 根据控制器状态向业务层发送当前播放进度。
  ///
  /// 播放器内部会保留邻近页控制器，因此这里必须用当前页索引和播放状态做双重过滤，
  /// 防止预加载或非当前页控制器的 position 变化触发业务联动。
  void _notifyPlaybackProgress(
    String key,
    VideoPlayerController controller,
  ) {
    final callback = widget.onPlaybackProgress;
    if (callback == null || widget.items.isEmpty) {
      return;
    }
    if (_currentIndex < 0 || _currentIndex >= widget.items.length) {
      return;
    }
    final currentItem = widget.items[_currentIndex];
    if (currentItem.key != key) {
      return;
    }
    final value = controller.value;
    if (!value.isInitialized || !value.isPlaying) {
      return;
    }

    final now = DateTime.now();
    if (_lastProgressKey != key) {
      _lastProgressKey = key;
      _lastProgressNotifiedAt = null;
    }
    final lastNotifiedAt = _lastProgressNotifiedAt;
    if (lastNotifiedAt != null &&
        now.difference(lastNotifiedAt) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastProgressNotifiedAt = now;
    callback(
      VideoPlaybackProgressEvent(
        item: currentItem,
        index: _currentIndex,
        position: value.position,
        duration: value.duration,
        isPlaying: value.isPlaying,
      ),
    );
  }

  /// 标记当前视频进入真实播放态。
  ///
  /// 只有当控制器已经成功调用 `play()` 后，才会开始累计播放时长，避免把预加载、
  /// 缓冲阶段误算进浏览上报。
  void _markPlaybackStarted({
    required IVideoItem item,
    required int index,
    VideoPlaybackStateChangeReason reason =
        VideoPlaybackStateChangeReason.playbackStarted,
  }) {
    final String nextKey = item.key;
    if (_activePlaybackKey == nextKey && _activePlaybackStartedAt != null) {
      return;
    }
    _activePlaybackKey = nextKey;
    _activePlaybackIndex = index;
    _activePlaybackStartedAt = DateTime.now();
    _notifyPlaybackState(
      item: item,
      index: index,
      state: VideoPlaybackState.started,
      reason: reason,
    );
  }

  /// 结算当前播放段并在需要时通知业务层。
  Future<void> _flushActivePlaybackSegment(
      VideoPlaybackStopReason reason) async {
    final String? activeKey = _activePlaybackKey;
    final DateTime? startedAt = _activePlaybackStartedAt;
    final int? playbackIndex = _activePlaybackIndex;
    if (activeKey == null || startedAt == null || playbackIndex == null) {
      _clearActivePlayback();
      return;
    }

    if (playbackIndex < 0 || playbackIndex >= widget.items.length) {
      _clearActivePlayback();
      return;
    }

    final IVideoItem item = widget.items[playbackIndex];
    if (item.key != activeKey) {
      _clearActivePlayback();
      return;
    }

    final Duration playedDuration = DateTime.now().difference(startedAt);
    _clearActivePlayback();
    _notifyPlaybackState(
      item: item,
      index: playbackIndex,
      state: VideoPlaybackState.paused,
      reason: switch (reason) {
        VideoPlaybackStopReason.pageChanged =>
          VideoPlaybackStateChangeReason.pageChanged,
        VideoPlaybackStopReason.invisible =>
          VideoPlaybackStateChangeReason.invisible,
        VideoPlaybackStopReason.appLifecycle =>
          VideoPlaybackStateChangeReason.appLifecycle,
        VideoPlaybackStopReason.manualPause =>
          VideoPlaybackStateChangeReason.manualPause,
        VideoPlaybackStopReason.autoplayDisabled =>
          VideoPlaybackStateChangeReason.autoplayDisabled,
        VideoPlaybackStopReason.controllerRemoved =>
          VideoPlaybackStateChangeReason.controllerRemoved,
        VideoPlaybackStopReason.released =>
          VideoPlaybackStateChangeReason.released,
        VideoPlaybackStopReason.disposed =>
          VideoPlaybackStateChangeReason.disposed,
      },
    );

    if (playedDuration.inSeconds < 1) {
      return;
    }
    final callback = widget.onPlaybackSegment;
    if (callback == null) {
      return;
    }
    await callback(
      VideoPlaybackSegment(
        item: item,
        index: playbackIndex,
        playedDuration: Duration(seconds: playedDuration.inSeconds),
        stopReason: reason,
      ),
    );
  }

  /// 清空当前播放段状态。
  void _clearActivePlayback() {
    _activePlaybackKey = null;
    _activePlaybackIndex = null;
    _activePlaybackStartedAt = null;
    _lastProgressKey = null;
    _lastProgressNotifiedAt = null;
  }

  /// 因组件不可见而暂停当前 feed。
  ///
  /// 这里不会修改 autoplay 开关，只是把已经在排队或正在缓冲的播放请求压回暂停态。
  Future<void> _pauseFeedForReason(VideoPlaybackStopReason reason) async {
    await _flushActivePlaybackSegment(reason);
    await VideoFeedSessionManager.instance.pauseGroup(widget.feedId);
    if (mounted) {
      setState(() {});
    }
  }

  /// 在允许播放时恢复当前索引对应的视频。
  ///
  /// 调用方无需关心控制器是否已经创建完成；该方法会先补齐当前控制器，
  /// 再次确认可播放条件仍成立后，才真正发起 `play()`。
  Future<void> _resumeCurrentIfAllowed() async {
    if (!_canStartPlayback ||
        widget.items.isEmpty ||
        _currentIndex >= widget.items.length) {
      return;
    }
    final item = widget.items[_currentIndex];
    await _getOrCreateController(item);
    final controller = _controllerCache[item.key];
    VideoFeedSessionManager.instance.setCurrent(widget.feedId, controller);
    if (!_canStartPlayback) {
      await _pauseFeedForReason(VideoPlaybackStopReason.invisible);
      return;
    }
    await _playController(item.key);
    if (mounted) {
      setState(() {});
    }
  }

  /// 初始化目标页控制器，并在任务仍有效时播放。
  Future<void> _initAndPlayVideo(int index, {int? generation}) async {
    if (widget.items.isEmpty || index >= widget.items.length) return;
    final normalized = _normalizeIndex(index);
    final item = widget.items[normalized];
    await _getOrCreateController(
      item,
      generation: generation,
      targetIndex: normalized,
    );
    if (!_isStableApplyActive(generation, normalized)) {
      return;
    }
    if (_canStartPlayback) {
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

  /// 获取或创建控制器。
  ///
  /// [generation] 与 [targetIndex] 用于稳态任务的过期校验，避免快滑时旧任务完成后
  /// 把已经离开窗口的控制器重新放回缓存。
  Future<VideoPlayerController?> _getOrCreateController(
    IVideoItem item, {
    int? generation,
    int? targetIndex,
  }) async {
    final key = item.key;
    if (!_isStableApplyActive(generation, targetIndex) ||
        !_shouldKeepControllerKey(key, targetIndex: targetIndex)) {
      return null;
    }
    if (_controllerCache.containsKey(key)) {
      _touchController(key);
      return _controllerCache[key];
    }

    if (_creationInFlight.containsKey(key)) {
      final controller = await _creationInFlight[key];
      if (!_isStableApplyActive(generation, targetIndex) ||
          !_shouldKeepControllerKey(key, targetIndex: targetIndex)) {
        return null;
      }
      return controller;
    }

    try {
      final int maxSize = _resolvedMaxControllers;
      if (_controllerCache.length >= maxSize) {
        final protectedKeys = _controllerKeysForTargetWindow(
          targetIndex ?? _currentIndex,
        )..remove(key);
        await _evictOne(
          policy: widget.evictionPolicy,
          protectedKeys: protectedKeys,
        );
      }

      final future = _createController(
        item,
        generation: generation,
        targetIndex: targetIndex,
      );
      _creationInFlight[key] = future;
      final controller = await future;
      _creationInFlight.remove(key);
      return controller;
    } catch (e) {
      _creationInFlight.remove(key);
      rethrow;
    }
  }

  /// 创建并初始化控制器。
  ///
  /// 初始化跨越 native MediaCodec/ExoPlayer，可能在用户快速滑走后才完成；因此
  /// 注册进缓存前必须再次确认任务 generation 与目标窗口仍有效。
  Future<VideoPlayerController?> _createController(
    IVideoItem item, {
    int? generation,
    int? targetIndex,
  }) async {
    final key = item.key;

    // 如果还没检查完设备信息且在Android上，等待一下
    if (Platform.isAndroid && !_deviceCheckDone) {
      await _checkDevice();
    }
    if (!_isStableApplyActive(generation, targetIndex) ||
        !_shouldKeepControllerKey(key, targetIndex: targetIndex)) {
      return null;
    }

    // 如果是华为设备，强制使用 platformView
    final VideoViewType effectiveViewType =
        _isHuawei ? VideoViewType.platformView : widget.viewType;

    final controller = await _controllerFactory.createAndInit(
      item,
      viewType: effectiveViewType,
      loop: widget.loop,
      volume: VolumeManager.instance.volume,
    );
    if (controller == null) return null;
    if (!_isStableApplyActive(generation, targetIndex) ||
        !_shouldKeepControllerKey(key, targetIndex: targetIndex)) {
      try {
        await controller.dispose();
      } catch (_) {}
      logging('dispose stale controller $key before register');
      return null;
    }
    _controllerCache[key] = controller;
    void progressListener() => _notifyPlaybackProgress(key, controller);
    _controllerProgressListeners[key] = progressListener;
    controller.addListener(progressListener);
    VideoFeedSessionManager.instance.register(widget.feedId, controller);
    _touchController(key);
    await _enforceCacheLimit(maxCacheSize: _resolvedMaxControllers);
    return controller;
  }

  /// 播放指定控制器
  Future<void> _playController(String key) async {
    final controller = _controllerCache[key];
    if (!_canStartPlayback) {
      await _pauseFeedForReason(VideoPlaybackStopReason.invisible);
      return;
    }
    if (!_isCurrentKey(key)) {
      return;
    }
    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.isPlaying) {
      try {
        await VideoFeedSessionManager.instance.playExclusive(
          widget.feedId,
          controller,
        );
        if (!_canStartPlayback || !_isCurrentKey(key)) {
          if (!_canStartPlayback) {
            await _pauseFeedForReason(VideoPlaybackStopReason.invisible);
          } else {
            try {
              await controller.pause();
            } catch (_) {}
          }
          return;
        }
        final int playbackIndex = widget.items.indexWhere(
          (item) => item.key == key,
        );
        if (playbackIndex != -1) {
          _markPlaybackStarted(
            item: widget.items[playbackIndex],
            index: playbackIndex,
          );
        }
        if (mounted) setState(() {});
      } catch (e) {
        logging('Error playing video: $e');
      }
    }
  }

  /// 移除并释放指定控制器
  Future<void> _removeController(String key) async {
    if (_disposingControllers.contains(key)) return;
    _disposingControllers.add(key);
    try {
      if (_activePlaybackKey == key) {
        await _flushActivePlaybackSegment(
          VideoPlaybackStopReason.controllerRemoved,
        );
      }
      final controller = _controllerCache[key];
      if (controller != null) {
        _controllerCache.remove(key);
        _accessOrder.remove(key);
        final progressListener = _controllerProgressListeners.remove(key);
        if (progressListener != null) {
          try {
            controller.removeListener(progressListener);
          } catch (_) {}
        }
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
          logging('Error disposing controller: $e');
        }
      }
    } finally {
      _disposingControllers.remove(key);
    }
  }

  /// 强制执行缓存上限。
  ///
  /// native 播放器释放不是零成本操作，必须等待释放完成后再继续创建新控制器，
  /// 否则快速滑动时容易叠加 MediaCodec 创建/释放压力。
  Future<void> _enforceCacheLimit({required int maxCacheSize}) async {
    while (_controllerCache.length > maxCacheSize && _accessOrder.isNotEmpty) {
      final oldestKey = _accessOrder.first;
      await _removeController(oldestKey);
    }
  }

  /// 驱逐一个控制器。
  ///
  /// [protectedKeys] 用于保护当前目标窗口中仍需要保留的控制器，优先驱逐窗口外缓存。
  Future<void> _evictOne({
    required EvictionPolicy policy,
    Set<String> protectedKeys = const <String>{},
  }) async {
    if (_controllerCache.isEmpty) return;
    final candidates = _accessOrder.isNotEmpty
        ? List<String>.from(_accessOrder)
        : List<String>.from(_controllerCache.keys);
    String evictKey = candidates.first;
    for (final candidate in candidates) {
      if (!protectedKeys.contains(candidate)) {
        evictKey = candidate;
        break;
      }
    }
    await _removeController(evictKey);
    logging('evict $evictKey policy=$policy size=${_controllerCache.length}');
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

  /// 管理控制器窗口。
  ///
  /// [generation] 用于让窗口内的控制器创建也遵循 latest-wins 语义。
  Future<void> _manageControllerWindow(
    int currentIndex, {
    int? generation,
  }) async {
    final normalized = _normalizeIndex(currentIndex);
    await manageControllerWindow(
      items: widget.items,
      currentIndex: normalized,
      maxCacheControllers: _resolvedMaxControllers,
      controllerCache: _controllerCache,
      removeController: _removeController,
      getOrCreateController: (item) => _getOrCreateController(
        item,
        generation: generation,
        targetIndex: normalized,
      ),
    );
  }

  /// 处理页面变化。
  ///
  /// 页面变化回调只做轻量状态同步；真正的控制器窗口管理与播放启动由稳态任务串行执行。
  Future<void> _handlePageChange(int newIndex) async {
    if (widget.items.isEmpty) return;
    final previousPageIndex = _lastPageViewIndex;
    _lastPageViewIndex = newIndex;
    final normalized = _normalizeIndex(newIndex);
    final isFastScroll = (newIndex - previousPageIndex).abs() > 1;
    try {
      if (!_isLatestPageChange(newIndex)) {
        return;
      }
      await _setCurrentIndex(
        normalized,
        reason: VideoPlaybackStopReason.pageChanged,
      );
      if (!_isLatestPageChange(newIndex, normalizedIndex: normalized)) {
        return;
      }
      final currentItem = widget.items[normalized];
      final currentKey = currentItem.key;

      final useEco = _updateEffectiveWindowForScroll(
        isFastScroll: isFastScroll,
      );

      await _preloadCoversAround(normalized);
      if (!_isLatestPageChange(newIndex, normalizedIndex: normalized)) {
        return;
      }

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
      }
      if (!_isLatestPageChange(newIndex, normalizedIndex: normalized)) {
        return;
      }

      _scheduleStablePageApply(
        normalized,
        duringScroll: false,
        markSettled: true,
      );
      if (mounted) setState(() {});
      widget.onIndexChanged?.call(normalized);
      logging(
        'page=$newIndex fast=$isFastScroll eco=$useEco effectivePreload=$_effectivePreload effectiveMax=$_effectiveMaxControllers active=${_controllerCache.length}',
      );
    } catch (e) {
      logging('Error handling page change: $e');
    }
  }

  /// 应用稳态页面逻辑。
  ///
  /// 该方法只允许由 [_drainStablePageApply] 串行调用；每个 await 后都检查
  /// generation，确保旧任务不会播放或注册已经过期的页面。
  Future<void> _applyStablePage(int targetIndex, int generation) async {
    if (widget.items.isEmpty) return;
    final normalized = _normalizeIndex(targetIndex);
    await _setCurrentIndex(
      normalized,
      reason: VideoPlaybackStopReason.pageChanged,
    );
    if (!_isStableApplyActive(generation, normalized)) {
      return;
    }
    await _manageControllerWindow(normalized, generation: generation);
    if (!_isStableApplyActive(generation, normalized)) {
      return;
    }
    await _initAndPlayVideo(normalized, generation: generation);
    if (!_isStableApplyActive(generation, normalized)) {
      return;
    }
    final currentItem = widget.items[normalized];
    final c = _controllerCache[currentItem.key];
    VideoFeedSessionManager.instance.setCurrent(widget.feedId, c);
    widget.onIndexChanged?.call(normalized);
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
      _invalidateStablePageApply();
      if (n is ScrollUpdateNotification) {
        final page = _pageController.page;
        final len = widget.items.length;
        if (page != null && len > 0) {
          final nearest = page.round();
          final frac = 1.0 - (page - nearest).abs();
          final threshold = widget.playThreshold.clamp(0.5, 1.0);
          if (frac >= threshold) {
            final normalized = _normalizeIndex(nearest);
            if (_currentIndex != normalized) {
              _scheduleStablePageApply(
                normalized,
                duringScroll: true,
                markSettled: false,
              );
            }
          }
        }
      }
    } else if (n is ScrollEndNotification ||
        (n is UserScrollNotification && n.direction == ScrollDirection.idle)) {
      _scheduleStablePageApply(
        _nearestLogicalIndex(),
        duringScroll: false,
        markSettled: true,
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return widget.emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return VisibilityDetector(
      key: ValueKey<String>('video-feed-${widget.feedId}'),
      onVisibilityChanged: _handleVisibilityChanged,
      child: LayoutBuilder(
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
                    (widget.showControllerOnlyOnCurrentPage
                            ? isCurrent
                            : true) &&
                        !_disposingControllers.contains(item.key);
                final safeController = shouldShowController ? controller : null;
                return RepaintBoundary(
                  key: ValueKey('${item.key}#$index'),
                  child: VideoPlayerTile(
                    controller: safeController,
                    videoId: item.key,
                    coverUrl: item.coverUrl,
                    videoWidth: item.videoWidth,
                    videoHeight: item.videoHeight,
                    videoCoverWidth: item.videoCoverWidth,
                    videoCoverHeight: item.videoCoverHeight,
                    coverFit: widget.coverFit,
                    videoDisplayMode: widget.videoDisplayMode,
                    viewportSize: viewportSize,
                    groupId: widget.feedId,
                    isCurrent: isCurrent,
                    onManualPause: () async {
                      if (logicalIndex != _currentIndex) {
                        return;
                      }
                      await _flushActivePlaybackSegment(
                        VideoPlaybackStopReason.manualPause,
                      );
                    },
                    onManualResume: () {
                      if (logicalIndex != _currentIndex) {
                        return;
                      }
                      _markPlaybackStarted(
                        item: item,
                        index: logicalIndex,
                        reason: VideoPlaybackStateChangeReason.manualResume,
                      );
                    },
                    bizWidgets: widget.bizWidgetsBuilder?.call(
                      context,
                      item,
                      logicalIndex,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
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
      futures.add(
        precacheImage(provider, context).then((_) {
          _preloadedCovers.add(item.coverUrl);
        }).catchError((_) {}),
      );
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }
}
