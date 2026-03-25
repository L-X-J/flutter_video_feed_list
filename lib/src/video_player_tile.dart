import 'dart:async';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'enums/video_display_mode.dart';
import 'services/feed_session_manager.dart';
import 'utils/logging.dart';
import 'video_layout.dart';

/// 单条视频播放组件
///
/// 承载 `VideoPlayerController` 的渲染与轻量交互，并根据 [videoDisplayMode]
/// 决定视频与封面的铺放方式。缓冲、错误、暂停与业务叠层统一在内部管理。
class VideoPlayerTile extends StatefulWidget {
  const VideoPlayerTile({
    required this.controller,
    required this.videoId,
    required this.coverUrl,
    this.coverFit,
    this.videoDisplayMode = VideoDisplayMode.cover,
    required this.viewportSize,
    this.bizWidgets,
    this.groupId,
    this.isCurrent = false,
    super.key,
  });

  /// 当前条目的视频控制器；为 null 时展示封面与加载指示
  final VideoPlayerController? controller;

  /// 视频唯一标识（用于变更监听与叠层状态）
  final String videoId;

  /// 视频封面图片地址
  final String coverUrl;

  /// 封面默认适配方式。
  ///
  /// 该参数主要用于兼容历史页面在 `cover` 模式下的占位图表现；
  /// 自适应与完整展示模式会优先使用内部统一布局决策。
  final BoxFit? coverFit;

  /// 视频展示模式。
  final VideoDisplayMode videoDisplayMode;

  /// 父容器的可用区域尺寸（用于封面与叠层布局）
  final Size viewportSize;

  /// 业务叠层组件列表（显示头像/点赞/描述等），覆盖在视频之上
  final List<Widget>? bizWidgets;
  final String? groupId;
  final bool isCurrent;

  @override
  State<VideoPlayerTile> createState() => _VideoPlayerTileState();
}

class _VideoPlayerTileState extends State<VideoPlayerTile>
    with TickerProviderStateMixin {
  /// 加载动画控制器（用于缓冲指示旋转）
  late AnimationController _loadingController;
  bool _isBuffering = false;
  VideoPlayerController? _oldController;
  String? _currentVideoId;
  bool _isPlaying = false;
  bool _isInitialized = false;
  Key _playerKey = UniqueKey();
  late AnimationController _overlayFade;
  bool _coverLoadingVisible = false;
  bool _bizReady = false;
  Timer? _bizDelayTimer;
  bool _lastShowCover = false;
  bool _bizInitApplied = false;
  Size? _coverImageSize;
  ImageStream? _coverImageStream;
  ImageStreamListener? _coverImageListener;

  @override
  void initState() {
    super.initState();
    _loadingController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _oldController = widget.controller;
    _currentVideoId = widget.videoId;
    _addControllerListener();
    _overlayFade = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _overlayFade.value = 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlayFade.forward();
    });
    _resolveCoverImageSize();
  }

  void _addControllerListener() {
    if (widget.controller != null) {
      try {
        _isBuffering = widget.controller!.value.isBuffering;
        _isPlaying = widget.controller!.value.isPlaying;
        _isInitialized = widget.controller!.value.isInitialized;
        _updateLoadingAnimation();
        widget.controller!.addListener(_onControllerUpdate);
      } catch (_) {}
    }
  }

  @override
  void didUpdateWidget(VideoPlayerTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool videoIdChanged = widget.videoId != _currentVideoId;
    final bool controllerChanged = widget.controller != _oldController;

    if (videoIdChanged || controllerChanged) {
      try {
        _oldController?.removeListener(_onControllerUpdate);
      } catch (_) {}
      _oldController = widget.controller;
      _currentVideoId = widget.videoId;
      _playerKey = UniqueKey();
      _addControllerListener();

      // 同步更新缓冲和播放状态
      final bool shouldUpdateBuffering =
          widget.controller?.value.isBuffering ?? false;
      final bool shouldUpdatePlaying =
          widget.controller?.value.isPlaying ?? false;
      final bool shouldUpdateInitialized =
          widget.controller?.value.isInitialized ?? false;
      if (mounted &&
          (_isBuffering != shouldUpdateBuffering ||
              _isPlaying != shouldUpdatePlaying ||
              _isInitialized != shouldUpdateInitialized)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _isBuffering = shouldUpdateBuffering;
              _isPlaying = shouldUpdatePlaying;
              _isInitialized = shouldUpdateInitialized;
              _updateLoadingAnimation();
            });
          }
        });
      }
    }

    if (oldWidget.coverUrl != widget.coverUrl) {
      _coverImageSize = null;
      _resolveCoverImageSize();
    }
    // 保持叠层稳定显示，不在每次更新时重新执行淡入，避免稳态切换时闪烁
  }

  @override
  void dispose() {
    _loadingController.dispose();
    try {
      _oldController?.removeListener(_onControllerUpdate);
    } catch (_) {}
    _oldController = null;
    _overlayFade.dispose();
    _bizDelayTimer?.cancel();
    _disposeCoverImageStream();
    super.dispose();
  }

  /// 解析封面图的原始尺寸。
  ///
  /// 在视频控制器尚未初始化完成时，播放器还拿不到真实视频宽高。
  /// 这里提前读取封面图尺寸，作为同一条内容在占位阶段的比例参考，
  /// 尽量保证“封面怎么展示，视频初始化后也怎么展示”。
  void _resolveCoverImageSize() {
    _disposeCoverImageStream();
    if (widget.coverUrl.isEmpty) {
      return;
    }
    final ImageProvider provider = NetworkImage(widget.coverUrl);
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    final ImageStreamListener listener = ImageStreamListener((image, _) {
      final Size nextSize = Size(
        image.image.width.toDouble(),
        image.image.height.toDouble(),
      );
      if (!mounted || _coverImageSize == nextSize) {
        return;
      }
      setState(() {
        _coverImageSize = nextSize;
      });
    });
    _coverImageStream = stream;
    _coverImageListener = listener;
    stream.addListener(listener);
  }

  /// 释放封面尺寸监听。
  ///
  /// 封面 URL 切换或组件销毁时必须解绑图片流监听，避免旧条目的异步回调串到
  /// 新视频上，造成封面比例偶发跳变。
  void _disposeCoverImageStream() {
    final stream = _coverImageStream;
    final listener = _coverImageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _coverImageStream = null;
    _coverImageListener = null;
  }

  /// 解析当前条目用于布局的参考尺寸。
  ///
  /// 优先级依次为：已初始化视频的真实宽高比、已解析出的封面尺寸、当前控制器可用尺寸、
  /// 最后才回退到视口本身。这样做的原因是：
  /// - 封面阶段优先保证首帧稳定，不闪不跳；
  /// - 播放阶段一旦拿到真实视频比例，就必须以视频自身为准，避免把 9:16 封面
  ///   的布局误套到 3:4 左右的视频上，造成“封面正常、视频被放大”的错觉。
  Size _resolveReferenceSize(VideoPlayerController? controller) {
    if (controller != null) {
      final Size? controllerAspectSize =
          _resolveControllerAspectSize(controller);
      if (controllerAspectSize != null) {
        return controllerAspectSize;
      }
      try {
        final Size controllerSize = controller.value.size;
        if (controllerSize.width > 0 &&
            controllerSize.height > 0 &&
            controllerSize.width.isFinite &&
            controllerSize.height.isFinite) {
          return controllerSize;
        }
      } catch (_) {}
    }
    final Size? coverImageSize = _coverImageSize;
    if (coverImageSize != null &&
        coverImageSize.width > 0 &&
        coverImageSize.height > 0 &&
        coverImageSize.width.isFinite &&
        coverImageSize.height.isFinite) {
      return coverImageSize;
    }
    return widget.viewportSize;
  }

  /// 根据控制器的真实宽高比生成用于布局的参考尺寸。
  ///
  /// 某些素材在平台层已经初始化完成，但 `size` 读取时机并不稳定；相比直接使用像素值，
  /// `aspectRatio` 更适合做布局决策。这里用一个归一化高度生成等比尺寸，让
  /// `FittedBox` 只关心比例，不依赖具体分辨率。
  Size? _resolveControllerAspectSize(VideoPlayerController controller) {
    try {
      final value = controller.value;
      if (!value.isInitialized) {
        return null;
      }
      final double aspectRatio = value.aspectRatio;
      if (!aspectRatio.isFinite || aspectRatio <= 0) {
        return null;
      }
      const double normalizedHeight = 1000;
      return Size(aspectRatio * normalizedHeight, normalizedHeight);
    } catch (_) {
      return null;
    }
  }

  void _onControllerUpdate() {
    if (!mounted) return;

    final controller = widget.controller;
    if (controller == null) return;

    if (widget.videoId != _currentVideoId) return;

    if (controller.value.hasError) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isBuffering = false;
            _isPlaying = false;
            _updateLoadingAnimation();
          });
        }
      });
      return;
    }

    final isBuffering = controller.value.isBuffering;
    final isPlaying = controller.value.isPlaying;
    final isInitialized = controller.value.isInitialized;

    final bool shouldShowBuffering = isBuffering && !controller.value.hasError;

    if (_isBuffering != shouldShowBuffering ||
        _isPlaying != isPlaying ||
        _isInitialized != isInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isBuffering = shouldShowBuffering;
            _isPlaying = isPlaying;
            _isInitialized = isInitialized;
            _updateLoadingAnimation();
          });
        }
      });
    }
  }

  void _updateLoadingAnimation() {
    if (_isBuffering) {
      if (!_loadingController.isAnimating) {
        _loadingController.repeat();
      }
    } else {
      if (_loadingController.isAnimating) {
        _loadingController.stop();
        _loadingController.reset();
      }
    }
  }

  /// 在统一的媒体可视区域内渲染子组件。
  ///
  /// 9:16 手机竖版素材会给底部业务区预留一段空间。这里把封面、视频和状态叠层
  /// 都裁剪到同一个区域里，避免各层边界不一致而产生“视频缩了、图标没缩”的错位。
  Widget _buildMediaViewport({
    required EdgeInsets mediaInsets,
    required Widget child,
  }) {
    return Positioned.fill(
      child: Padding(
        padding: mediaInsets,
        child: ClipRect(child: child),
      ),
    );
  }

  /// 在媒体可视区域中构建居中的提示层。
  ///
  /// 缓冲、错误、暂停图标都应该相对“实际视频区域”居中，而不是相对整屏黑底居中；
  /// 否则在底部额外留出业务区后，图标会明显偏下。
  Widget _buildCenteredMediaOverlay({
    required EdgeInsets mediaInsets,
    required Widget child,
  }) {
    return _buildMediaViewport(
      mediaInsets: mediaInsets,
      child: IgnorePointer(child: Center(child: child)),
    );
  }

  @override
  Widget build(BuildContext context) {
    /// 渲染规则：
    /// - 控制器未就绪：显示封面与加载指示；
    /// - 控制器就绪：按统一布局决策渲染视频；
    /// - 封面、视频、中间态叠层共用同一块媒体区域，避免自适应模式下层与层错位。
    final controller = widget.controller;
    bool safelyInitialized = false;
    if (controller != null) {
      try {
        safelyInitialized = controller.value.isInitialized;
      } catch (_) {
        safelyInitialized = false;
      }
    }

    bool hasError = false;
    if (controller != null) {
      try {
        hasError = controller.value.hasError;
      } catch (_) {
        hasError = true;
      }
    }
    final showCover = controller == null || !safelyInitialized || hasError;
    final coverOpacity = showCover ? 1.0 : 0.0;
    final Size baseSize = _resolveReferenceSize(controller);
    final VideoLayoutDecision layoutDecision = resolveVideoLayout(
      displayMode: widget.videoDisplayMode,
      viewportSize: widget.viewportSize,
      videoSize: baseSize,
      fallbackCoverFit: widget.coverFit,
    );
    final EdgeInsets mediaInsets = layoutDecision.mediaInsets;

    if (showCover != _lastShowCover) {
      _lastShowCover = showCover;
      if (showCover) {
        _bizDelayTimer?.cancel();
        _bizReady = false;
        _coverLoadingVisible = true;
        _bizInitApplied = false;
      } else {
        _coverLoadingVisible = false;
        _bizDelayTimer?.cancel();
        _bizDelayTimer = Timer(const Duration(milliseconds: 120), () {
          if (!mounted) return;
          setState(() {
            _bizReady = true;
          });
        });
      }
    }

    if (!showCover &&
        !_bizReady &&
        !_bizInitApplied &&
        _bizDelayTimer == null) {
      _bizInitApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _bizReady = true;
        });
      });
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: layoutDecision.backgroundColor),
        ),
        // 封面
        _buildMediaViewport(
          mediaInsets: mediaInsets,
          child: AnimatedOpacity(
            opacity: coverOpacity,
            duration: const Duration(milliseconds: 200),
            child: Builder(builder: (context) {
              return FittedBox(
                fit: layoutDecision.coverFit,
                alignment: layoutDecision.alignment,
                child: SizedBox(
                  width: baseSize.width,
                  height: baseSize.height,
                  child: ExtendedImage.network(
                    widget.coverUrl,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.low,
                    cache: true,
                    clearMemoryCacheWhenDispose: true,
                    // cacheWidth: (cacheWidth / 2).round(),
                    // cacheHeight: (cacheHeight / 2).round(),
                  ),
                ),
              );
            }),
          ),
        ),

        // 视频
        _buildMediaViewport(
          mediaInsets: mediaInsets,
          child: InkWell(
            onTap: () {
              if (controller == null) return;
              final c = controller;
              bool canUse = false;
              try {
                canUse = c.value.isInitialized && !c.value.hasError;
              } catch (_) {
                canUse = false;
              }
              if (!canUse) return;

              final wasPlaying = c.value.isPlaying;
              if (wasPlaying) {
                // 立即更新状态，避免显示延迟
                setState(() {
                  _isPlaying = false;
                });
                c.pause().then((_) {
                  if (mounted) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => mounted ? setState(() {}) : null);
                  }
                }).catchError((Object e) {
                  logging('Error pausing video: $e');
                });
              } else {
                // 立即更新状态，避免显示延迟
                setState(() {
                  _isPlaying = true;
                });
                VideoFeedSessionManager.instance
                    .playExclusive(widget.groupId ?? '', c)
                    .then((_) {
                  if (mounted) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => mounted ? setState(() {}) : null);
                  }
                }).catchError((Object e) {
                  logging('Error playing video: $e');
                });
              }
            },
            child: FittedBox(
              key: _playerKey,
              fit: layoutDecision.videoFit,
              alignment: layoutDecision.alignment,
              child: SizedBox(
                width: baseSize.width,
                height: baseSize.height,
                child: !showCover
                    ? VideoPlayer(controller)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),

        if (showCover && widget.isCurrent && !hasError && _coverLoadingVisible)
          _buildCenteredMediaOverlay(
            mediaInsets: mediaInsets,
            child: const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ),
          ),

        if (controller != null) ..._buildOverlays(controller, mediaInsets),
        if (widget.bizWidgets != null)
          AnimatedOpacity(
            opacity: (_bizReady && !showCover) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 120),
            child: IgnorePointer(
              ignoring: !(_bizReady && !showCover),
              child: Stack(children: widget.bizWidgets!),
            ),
          ),
      ],
    );
  }

  /// 构建视频状态叠层。
  ///
  /// 这些叠层需要和实际媒体区域完全同步，否则 9:16 视频在顶部贴顶、底部留业务区时，
  /// 缓冲与暂停提示会掉到黑底区域里，影响观感和点击预期。
  List<Widget> _buildOverlays(
    VideoPlayerController controller,
    EdgeInsets mediaInsets,
  ) {
    // 安全获取控制器状态
    bool hasError = false;
    bool isInitialized = false;
    try {
      hasError = controller.value.hasError;
      isInitialized = controller.value.isInitialized;
    } catch (_) {
      hasError = true;
      isInitialized = false;
    }

    // 只有在视频已初始化时才显示叠层
    if (!isInitialized) {
      return [];
    }

    return [
      // 缓冲指示器：优先显示，当正在缓冲时显示
      if (_isBuffering)
        _buildCenteredMediaOverlay(
          mediaInsets: mediaInsets,
          child: RotationTransition(
            turns: Tween<double>(begin: 0, end: 1).animate(_loadingController),
            child: const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2.5),
            ),
          ),
        ),
      // 错误指示器：有错误时显示
      if (hasError)
        _buildCenteredMediaOverlay(
          mediaInsets: mediaInsets,
          child: const Icon(Icons.error_outline,
              color: Colors.redAccent, size: 72),
        ),
      // 暂停图标：只在视频暂停、没有缓冲、没有错误时显示
      // 使用 _isPlaying 而不是 controller.value.isPlaying 确保状态同步
      if (!_isPlaying && !_isBuffering && !hasError)
        _buildCenteredMediaOverlay(
          mediaInsets: mediaInsets,
          child: const Icon(
            Icons.pause_circle_filled,
            color: Colors.white,
            size: 48,
          ),
        ),
    ];
  }
}
