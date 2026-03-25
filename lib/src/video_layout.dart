// 视频铺放策略计算。
//
// 该文件专门负责把“素材比例 + 视口尺寸 + 展示模式”解析成稳定的渲染决策，
// 让封面、正式视频和中间态叠层都共享同一套布局约束，避免页面在首帧和播放态之间
// 出现跳变。
import 'package:flutter/material.dart';

import 'enums/video_display_mode.dart';

/// 视频布局决策结果。
///
/// 该对象只在组件库内部流转，用于让封面与正式视频共用同一份布局计算结果，
/// 避免控制器初始化前后出现裁切策略跳变。
class VideoLayoutDecision {
  /// 视频层使用的适配方式。
  final BoxFit videoFit;

  /// 封面层使用的适配方式。
  final BoxFit coverFit;

  /// 视频与封面共用的对齐方式。
  final Alignment alignment;

  /// 留白区域使用的背景色。
  final Color backgroundColor;

  /// 媒体内容相对整个卡片的额外内边距。
  ///
  /// 该值只作用于视频与封面本身，不影响业务叠层的位置。当前主要用于 9:16
  /// 手机竖版素材：顶部继续贴顶，底部额外预留一段业务区，避免视频直接压到
  /// 头像、操作按钮等底部信息上。
  final EdgeInsets mediaInsets;

  /// 构造一个不可变的布局决策结果。
  const VideoLayoutDecision({
    required this.videoFit,
    required this.coverFit,
    required this.alignment,
    this.backgroundColor = Colors.black,
    this.mediaInsets = EdgeInsets.zero,
  });
}

/// 根据视频尺寸与视口尺寸解析最终展示布局。
///
/// 当 [videoSize] 无效时会回退到保守策略，保证首屏封面阶段也能稳定渲染。
/// [fallbackCoverFit] 仅在 [VideoDisplayMode.cover] 下生效，用于兼容旧版封面表现。
VideoLayoutDecision resolveVideoLayout({
  required VideoDisplayMode displayMode,
  required Size viewportSize,
  required Size videoSize,
  BoxFit? fallbackCoverFit,
}) {
  final bool hasViewport = viewportSize.width > 0 &&
      viewportSize.height > 0 &&
      viewportSize.width.isFinite &&
      viewportSize.height.isFinite;
  final bool hasVideoSize = videoSize.width > 0 &&
      videoSize.height > 0 &&
      videoSize.width.isFinite &&
      videoSize.height.isFinite;

  if (!hasViewport) {
    return VideoLayoutDecision(
      videoFit: BoxFit.cover,
      coverFit: fallbackCoverFit ?? BoxFit.fitHeight,
      alignment: Alignment.center,
    );
  }

  switch (displayMode) {
    case VideoDisplayMode.cover:
      return VideoLayoutDecision(
        videoFit: BoxFit.cover,
        coverFit: fallbackCoverFit ?? BoxFit.fitHeight,
        alignment: Alignment.center,
      );
    case VideoDisplayMode.contain:
      return const VideoLayoutDecision(
        videoFit: BoxFit.contain,
        coverFit: BoxFit.contain,
        alignment: Alignment.center,
      );
    case VideoDisplayMode.adaptive:
      if (!hasVideoSize) {
        return const VideoLayoutDecision(
          videoFit: BoxFit.contain,
          coverFit: BoxFit.contain,
          alignment: Alignment.center,
        );
      }
      return _resolveAdaptiveVideoLayout(
        viewportSize: viewportSize,
        videoSize: videoSize,
      );
  }
}

/// 解析自适应展示模式下的布局结果。
///
/// 规则以“完整展示优先，9:16 竖版贴顶优先”为目标：
/// - 横屏、方形、3:4 等非 9:16 竖版素材统一使用 `contain + center`；
/// - 仅当视频宽高比接近 9:16，且按宽度铺满后不会超出视口高度时，
///   才在窄屏手机上采用“顶部贴顶 + 轻微横向裁切”的舞台布局；
/// - 如果为了贴近底部业务区而需要明显放大，导致横向裁切超过阈值，
///   则回退为 `contain + center`，避免把接近 3:4 的竖版视频硬撑成 9:16 效果。
///
/// 这里的“轻微裁切”本质上是业务可接受的轻度放大，并不是任意比例都允许被顶满。
///   视频不会一直铺到屏幕底部，而是给底部业务信息留出一小段稳定空间。
VideoLayoutDecision _resolveAdaptiveVideoLayout({
  required Size viewportSize,
  required Size videoSize,
}) {
  final double aspectRatio = videoSize.width / videoSize.height;
  final bool isNearPhonePortrait = aspectRatio >= 0.52 && aspectRatio <= 0.60;
  final double fitWidthHeight = viewportSize.width / aspectRatio;
  final bool canFitWidthWithoutCropping = fitWidthHeight <= viewportSize.height;
  final bool preferTopAlignedPortrait = viewportSize.width < 700;

  if (isNearPhonePortrait && canFitWidthWithoutCropping) {
    final double portraitBottomInset = preferTopAlignedPortrait
        ? _resolvePhonePortraitBottomInset(
            viewportSize: viewportSize,
            fitWidthHeight: fitWidthHeight,
          )
        : 0;
    final double targetStageHeight = viewportSize.height - portraitBottomInset;
    final double stagedWidth = targetStageHeight * aspectRatio;
    final double horizontalOverfillRatio =
        viewportSize.width <= 0 ? 1 : stagedWidth / viewportSize.width;

    // 允许适度放大，让 9:16 素材更贴近底部业务区；但一旦横向裁切过重，
    // 画面会呈现明显“被拉大”的感觉，此时宁可回退为完整居中，也不要强顶满。
    const double maxAcceptedHorizontalOverfillRatio = 1.12;
    final bool canUsePortraitStage = portraitBottomInset > 0 &&
        horizontalOverfillRatio <= maxAcceptedHorizontalOverfillRatio;

    if (canUsePortraitStage) {
      return VideoLayoutDecision(
        videoFit: BoxFit.cover,
        coverFit: BoxFit.cover,
        alignment:
            preferTopAlignedPortrait ? Alignment.topCenter : Alignment.center,
        mediaInsets: EdgeInsets.only(bottom: portraitBottomInset),
      );
    }
  }

  return const VideoLayoutDecision(
    videoFit: BoxFit.contain,
    coverFit: BoxFit.contain,
    alignment: Alignment.center,
  );
}

/// 计算手机 9:16 竖版视频底部需要预留的业务区高度。
///
/// 纯 `fitWidth` 会让 9:16 素材顶部贴顶，但底部留下完整黑边；而直接全屏 `cover`
/// 又会把两侧裁掉太多。这里保留原始底部留白的一部分，只吃掉中间那段“显得空”的
/// 区域，让视频底边更接近头像上方，同时把横向裁切控制在较轻的范围内。
double _resolvePhonePortraitBottomInset({
  required Size viewportSize,
  required double fitWidthHeight,
}) {
  final double naturalBottomGap =
      (viewportSize.height - fitWidthHeight).clamp(0.0, double.infinity);

  if (naturalBottomGap <= 0) {
    return 0;
  }

  const double keepGapFraction = 0.65;
  return naturalBottomGap * keepGapFraction;
}
