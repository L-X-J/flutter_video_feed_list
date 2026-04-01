abstract class IVideoItem {
  /// 视频播放地址。
  String get videoUrl;

  /// 视频封面地址。
  String get coverUrl;

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
    this.id,
    this.analyticsId,
  });

  @override
  final String videoUrl;

  @override
  final String coverUrl;

  @override
  final String? id;

  @override
  final String? analyticsId;

  @override
  String get key => id ?? videoUrl;
}
