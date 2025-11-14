import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:extended_image/extended_image.dart';
import 'services/feed_session_manager.dart';

/// 单条视频播放组件
///
/// 承载 `VideoPlayerController` 的渲染与轻量交互，采用 FittedBox Cover 显示，
/// 保证铺满且不变形；缓冲/错误/暂停等叠层在内部统一管理。
class VideoPlayerTile extends StatefulWidget {
  const VideoPlayerTile({
    required this.controller,
    required this.videoId,
    required this.coverUrl,
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
  Key _playerKey = UniqueKey();
  late AnimationController _overlayFade;

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
  }

  void _addControllerListener() {
    if (widget.controller != null) {
      try {
        _isBuffering = widget.controller!.value.isBuffering;
        _isPlaying = widget.controller!.value.isPlaying;
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

      final bool shouldUpdateBuffering =
          widget.controller?.value.isBuffering ?? false;
      if (mounted && _isBuffering != shouldUpdateBuffering) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _isBuffering = shouldUpdateBuffering;
            });
          }
        });
      }
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
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;

    final controller = widget.controller;
    if (controller == null) return;

    if (widget.videoId != _currentVideoId) return;

    if (controller.value.hasError) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _isBuffering = false);
      });
      return;
    }

    final isBuffering = controller.value.isBuffering;
    final isPlaying = controller.value.isPlaying;

    final bool shouldShowBuffering = isBuffering && !controller.value.hasError;

    if (_isBuffering != shouldShowBuffering || _isPlaying != isPlaying) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isBuffering = shouldShowBuffering;
            _isPlaying = isPlaying;
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

  @override
  Widget build(BuildContext context) {
    /// 渲染规则：
    /// - 控制器未就绪：显示封面与加载指示（StackFit.expand）
    /// - 控制器就绪：使用 FittedBox(BoxFit.cover) 保证铺满且不变形，
    ///   并在最上层叠加缓冲/错误/暂停与业务组件
    final controller = widget.controller;
    bool safelyInitialized = false;
    if (controller != null) {
      try {
        safelyInitialized = controller.value.isInitialized;
      } catch (_) {
        safelyInitialized = false;
      }
    }

    bool hasError = true;
    try {
      hasError = controller?.value.hasError ?? true;
    } catch (_) {
      hasError = true;
    }
    final showCover = controller == null || !safelyInitialized || hasError;
    final coverOpacity = showCover ? 1.0 : 0.0;
    final Size baseSize =
        safelyInitialized ? controller!.value.size : widget.viewportSize;

    return ClipRect(
      child: SizedBox.expand(
        child: Stack(
          children: [
            // 封面
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: coverOpacity,
                duration: const Duration(milliseconds: 200),
                child: Builder(builder: (context) {
                  final dpr = MediaQuery.of(context).devicePixelRatio;
                  final cacheWidth = (widget.viewportSize.width * dpr).round();
                  final cacheHeight =
                      (widget.viewportSize.height * dpr).round();
                  return ExtendedImage.network(
                    widget.coverUrl,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    cache: true,
                    clearMemoryCacheWhenDispose: true,
                    cacheWidth: cacheWidth,
                    cacheHeight: cacheHeight,
                  );
                }),
              ),
            ),
            // 视频
            Positioned.fill(
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

                  if (c.value.isPlaying) {
                    c
                        .pause()
                        .then((_) => WidgetsBinding.instance
                            .addPostFrameCallback(
                                (_) => mounted ? setState(() {}) : null))
                        .catchError((Object e) =>
                            debugPrint('Error pausing video: $e'));
                  } else {
                    VideoFeedSessionManager.instance
                        .playExclusive(widget.groupId ?? '', c)
                        .then((_) => WidgetsBinding.instance
                            .addPostFrameCallback(
                                (_) => mounted ? setState(() {}) : null))
                        .catchError((Object e) =>
                            debugPrint('Error playing video: $e'));
                  }
                },
                child: FittedBox(
                  key: _playerKey,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: baseSize.width,
                    height: baseSize.height,
                    child: (!showCover && controller != null)
                        ? VideoPlayer(controller)
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),

            if (showCover)
              FutureBuilder(
                  future: Future.delayed(const Duration(milliseconds: 300)),
                  builder: (_, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        showCover) {
                      return const Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 4),
                            ),
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }),

            if (controller != null) ..._buildOverlays(context, controller),
            if (widget.bizWidgets != null)
              FutureBuilder(
                  future: Future.delayed(const Duration(milliseconds: 120)),
                  builder: (_, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        !showCover) {
                      return IgnorePointer(
                        ignoring: showCover,
                        child: Stack(children: widget.bizWidgets!),
                      );
                    }
                    return const SizedBox.shrink();
                  })
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOverlays(
      BuildContext context, VideoPlayerController controller) {
    return [
      if (_isBuffering)
        IgnorePointer(
          child: Center(
            child: RotationTransition(
              turns:
                  Tween<double>(begin: 0, end: 1).animate(_loadingController),
              child: const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5),
              ),
            ),
          ),
        ),
      if (controller.value.hasError)
        const IgnorePointer(
          child: Center(
            child: Icon(Icons.error_outline, color: Colors.redAccent, size: 72),
          ),
        ),
      if (!controller.value.isPlaying &&
          !_isBuffering &&
          !controller.value.hasError)
        const IgnorePointer(
          child: Center(
            child:
                Icon(Icons.pause_circle_filled, color: Colors.white, size: 48),
          ),
        ),
    ];
  }
}
