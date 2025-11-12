abstract class IVideoItem {
  String get videoUrl;
  String get coverUrl;
  String? get id;
  String get key => id ?? videoUrl;
}

class DefaultVideoItem implements IVideoItem {
  const DefaultVideoItem({
    required this.videoUrl,
    required this.coverUrl,
    this.id,
  });

  @override
  final String videoUrl;

  @override
  final String coverUrl;

  @override
  final String? id;

  @override
  String get key => id ?? videoUrl;
}
