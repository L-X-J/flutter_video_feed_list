/// 视频条目实体（支持外部继承与泛型载荷）
///
/// 表示视频源与封面资源的最小集合，`key` 用于缓存与控制器索引。
/// 当未提供 `id` 时，以 `videoUrl` 作为唯一标识。
///
/// 泛型参数 [T] 可用于承载业务自定义数据（例如作者信息、统计数据等）。
class VideoItem<T> {
  /// 构造函数
  ///
  /// - [videoUrl] 视频播放地址（文件或网络）
  /// - [coverUrl] 视频封面图片地址
  /// - [id] 可选的业务唯一标识；未提供时以 [videoUrl] 作为唯一键
  /// - [data] 业务自定义载荷（可选）
  const VideoItem({
    required this.videoUrl,
    required this.coverUrl,
    this.id,
    this.data,
  });

  /// 视频播放地址（文件或网络）
  final String videoUrl;

  /// 视频封面图片地址
  final String coverUrl;

  /// 业务唯一标识，可选
  final String? id;

  /// 业务自定义载荷（泛型），可选
  final T? data;

  /// 用于缓存与控制器索引的唯一键
  ///
  /// 优先使用 [id]；未提供时退化为 [videoUrl]
  String get key => id ?? videoUrl;
}
