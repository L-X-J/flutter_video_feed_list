import 'package:video_player/video_player.dart';

class VideoFeedSessionManager {
  VideoFeedSessionManager._();
  static final VideoFeedSessionManager instance = VideoFeedSessionManager._();

  final Map<String, Set<VideoPlayerController>> _groups = {};
  final Map<String, VideoPlayerController?> _current = {};

  void register(String groupId, VideoPlayerController controller) {
    final set = _groups.putIfAbsent(groupId, () => <VideoPlayerController>{});
    set.add(controller);
  }

  void unregister(String groupId, VideoPlayerController controller) {
    final set = _groups[groupId];
    set?.remove(controller);
    if (set != null && set.isEmpty) {
      _groups.remove(groupId);
      _current.remove(groupId);
    }
  }

  void setCurrent(String groupId, VideoPlayerController? controller) {
    _current[groupId] = controller;
  }

  Future<void> pauseAll() async {
    for (final set in _groups.values) {
      for (final c in List<VideoPlayerController>.from(set)) {
        try {
          if (c.value.isInitialized && c.value.isPlaying) {
            await c.pause();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> resumeAll() async {
    for (final entry in _current.entries) {
      final c = entry.value;
      if (c == null) continue;
      try {
        if (c.value.isInitialized && !c.value.isPlaying && !c.value.hasError) {
          await c.play();
        }
      } catch (_) {}
    }
  }

  Future<void> pauseGroup(String groupId) async {
    final set = _groups[groupId];
    if (set == null) return;
    for (final c in List<VideoPlayerController>.from(set)) {
      try {
        if (c.value.isInitialized && c.value.isPlaying) {
          await c.pause();
        }
      } catch (_) {}
    }
  }

  Future<void> resumeGroup(String groupId) async {
    final c = _current[groupId];
    if (c == null) return;
    try {
      if (c.value.isInitialized && !c.value.isPlaying && !c.value.hasError) {
        await c.play();
      }
    } catch (_) {}
  }

  Future<void> pauseOthers(String groupId) async {
    for (final id in List<String>.from(_groups.keys)) {
      if (id == groupId) continue;
      await pauseGroup(id);
    }
  }

  void clearGroup(String groupId) {
    _groups.remove(groupId);
    _current.remove(groupId);
  }
}
