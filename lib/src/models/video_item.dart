abstract class IVideoItem {
  /// 视频播放地址。
  String get videoUrl;

  /// 视频封面地址。
  String get coverUrl;

  /// 服务端返回的视频原始宽度。
  ///
  /// 播放器优先使用该字段做视频阶段的布局决策，避免等待控制器初始化后才拿到
  /// 尺寸而触发二次布局。
  int? get videoWidth => null;

  /// 服务端返回的视频原始高度。
  int? get videoHeight => null;

  /// 服务端返回的封面图原始宽度。
  ///
  /// 封面阶段优先使用该字段做布局决策，避免为了获取图片尺寸而额外解析网络图。
  int? get videoCoverWidth => null;

  /// 服务端返回的封面图原始高度。
  int? get videoCoverHeight => null;

  /// 用于播放器缓存和页面渲染稳定性的标识。
  String? get id;

  /// 业务侧主键。
  ///
  /// 该字段不会参与播放器内部缓存键计算，主要用于浏览上报、埋点或其他业务逻辑
  /// 在回调里稳定识别同一条内容。
  String? get analyticsId => null;

  String get key => id ?? videoUrl;
}

class DefaultVideoItem implements IVideoItem {
  const DefaultVideoItem({
    required this.videoUrl,
    required this.coverUrl,
    this.videoWidth,
    this.videoHeight,
    this.videoCoverWidth,
    this.videoCoverHeight,
    this.id,
    this.analyticsId,
  });

  @override
  final String videoUrl;

  @override
  final String coverUrl;

  @override
  final int? videoWidth;

  @override
  final int? videoHeight;

  @override
  final int? videoCoverWidth;

  @override
  final int? videoCoverHeight;

  @override
  final String? id;

  @override
  final String? analyticsId;

  @override
  String get key => id ?? videoUrl;
}
