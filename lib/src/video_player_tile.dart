import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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

  @override
  State<VideoPlayerTile> createState() => _VideoPlayerTileState();
}

class _VideoPlayerTileState extends State<VideoPlayerTile>
    with SingleTickerProviderStateMixin {
  /// 加载动画控制器（用于缓冲指示旋转）
  late AnimationController _loadingController;
  bool _isBuffering = false;
  VideoPlayerController? _oldController;
  String? _currentVideoId;
  bool _isPlaying = false;
  Key _playerKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _loadingController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _oldController = widget.controller;
    _currentVideoId = widget.videoId;
    _addControllerListener();
  }

  void _addControllerListener() {
    if (widget.controller != null) {
      _isBuffering = widget.controller!.value.isBuffering;
      _isPlaying = widget.controller!.value.isPlaying;
      _updateLoadingAnimation();
      widget.controller!.addListener(_onControllerUpdate);
    }
  }

  @override
  void didUpdateWidget(VideoPlayerTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool videoIdChanged = widget.videoId != _currentVideoId;
    final bool controllerChanged = widget.controller != _oldController;

    if (videoIdChanged || controllerChanged) {
      _oldController?.removeListener(_onControllerUpdate);
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
  }

  @override
  void dispose() {
    _loadingController.dispose();
    _oldController?.removeListener(_onControllerUpdate);
    _oldController = null;
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

    bool shouldShowBuffering = isBuffering;
    if ((isPlaying && controller.value.position > Duration.zero) ||
        (controller.value.position > Duration.zero &&
            controller.value.duration.inMilliseconds > 0)) {
      shouldShowBuffering = false;
    }

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

    if (controller == null || !safelyInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            widget.coverUrl,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            cacheWidth: 540,
            cacheHeight: 960,
          ),
          IgnorePointer(
            child: Center(
              child: RotationTransition(
                turns:
                    Tween<double>(begin: 0, end: 1).animate(_loadingController),
                child: const CircularProgressIndicator(color: Colors.white),
              ),
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: () {
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
              .then((_) => WidgetsBinding.instance.addPostFrameCallback(
                  (_) => mounted ? setState(() {}) : null))
              .catchError((Object e) => debugPrint('Error pausing video: $e'));
        } else {
          c
              .play()
              .then((_) => WidgetsBinding.instance.addPostFrameCallback(
                  (_) => mounted ? setState(() {}) : null))
              .catchError((Object e) => debugPrint('Error playing video: $e'));
        }
      },
      child: ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            key: _playerKey,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: _buildVideoSurface(context, controller),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSurface(
      BuildContext context, VideoPlayerController controller) {
    /// 视频表面：底层为 VideoPlayer，叠加缓冲/错误/暂停，以及业务自定义组件
    final child = Stack(
      children: [
        VideoPlayer(controller),
        // 加载/缓冲中显示旋转进度
        if (_isBuffering)
          IgnorePointer(
            child: Center(
              child: RotationTransition(
                turns:
                    Tween<double>(begin: 0, end: 1).animate(_loadingController),
                child: const CircularProgressIndicator(color: Colors.white),
              ),
            ),
          ),
        // 错误状态提示
        if (controller.value.hasError)
          const IgnorePointer(
            child: Center(
              child:
                  Icon(Icons.error_outline, color: Colors.redAccent, size: 72),
            ),
          ),
        // 暂停时显示暂停图标覆盖层（不拦截点击）
        if (!controller.value.isPlaying &&
            !_isBuffering &&
            !controller.value.hasError)
          const IgnorePointer(
            child: Center(
              child: Icon(Icons.pause_circle_filled,
                  color: Colors.white, size: 80),
            ),
          ),
        if (widget.bizWidgets != null) ...widget.bizWidgets!,
      ],
    );
    return child;
  }
}
