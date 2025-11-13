import 'package:video_player/video_player.dart';

/// 视频信息流会话管理器
///
/// 负责跨页面/跨分组的控制器编排与播放状态管理。
///
/// 概念说明：
/// - 分组（groupId）：通常对应一个页面（如 A、B、C），用于隔离各自的控制器集合
/// - 当前控制器（current）：每个分组内可标记一个“当前播放”的控制器
/// - 委托（delegates）：由页面注册的行为回调，用于执行特定策略（如仅保留当前、恢复窗口）
class VideoFeedSessionManager {
  VideoFeedSessionManager._();
  static final VideoFeedSessionManager instance = VideoFeedSessionManager._();

  /// 分组到控制器集合的映射：`groupId -> {controllers}`
  final Map<String, Set<VideoPlayerController>> _groups = {};

  /// 分组到“当前控制器”的映射：`groupId -> controller`
  final Map<String, VideoPlayerController?> _current = {};

  /// 分组的“清理委托”：清理除当前位置外其他控制器的缓存
  final Map<String, Future<void> Function()?> _clearOthersKeepCurrent = {};

  /// 分组的“窗口恢复委托”：根据页面策略恢复相邻位置的缓存窗口
  final Map<String, Future<void> Function()?> _restoreWindowDelegates = {};

  /// 注册控制器到分组
  ///
  /// - 在控制器创建成功后调用，将其归入对应的 `groupId`
  void register(String groupId, VideoPlayerController controller) {
    final set = _groups.putIfAbsent(groupId, () => <VideoPlayerController>{});
    set.add(controller);
  }

  /// 从分组中注销控制器
  ///
  /// - 在控制器释放前调用，移除其在会话管理中的索引
  void unregister(String groupId, VideoPlayerController controller) {
    final set = _groups[groupId];
    set?.remove(controller);
    if (set != null && set.isEmpty) {
      _groups.remove(groupId);
      _current.remove(groupId);
    }
  }

  /// 标记分组内的“当前控制器”
  ///
  /// - 页面在索引稳定或播放切换时调用，用于恢复/继续播放的参考
  void setCurrent(String groupId, VideoPlayerController? controller) {
    _current[groupId] = controller;
  }

  /// 暂停所有分组中的所有控制器
  ///
  /// - 用于全局打断（如进入覆盖层、浮层弹窗等）
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

  /// 恢复所有分组的“当前控制器”播放
  ///
  /// - 仅尝试恢复各分组已标记为当前的控制器，避免同时多路播放
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

  /// 暂停指定分组内全部控制器
  ///
  /// - 用于页面间互斥播放：进入页面 B 时暂停页面 A 的播放
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

  /// 恢复指定分组的“当前控制器”播放
  ///
  /// - 仅恢复该分组当前标记的控制器，避免多路并行
  Future<void> resumeGroup(String groupId) async {
    final c = _current[groupId];
    if (c == null) return;
    try {
      if (c.value.isInitialized && !c.value.isPlaying && !c.value.hasError) {
        await c.play();
      }
    } catch (_) {}
  }

  /// 暂停除指定分组外的所有分组控制器
  ///
  /// - 用于进入新页面时打断其他页面的播放
  Future<void> pauseOthers(String groupId) async {
    for (final id in List<String>.from(_groups.keys)) {
      if (id == groupId) continue;
      await pauseGroup(id);
    }
  }

  /// 清空分组的会话信息
  ///
  /// - 移除分组内的控制器索引与当前控制器标记，以及委托
  void clearGroup(String groupId) {
    _groups.remove(groupId);
    _current.remove(groupId);
    _clearOthersKeepCurrent.remove(groupId);
    _restoreWindowDelegates.remove(groupId);
  }

  /// 查询分组内是否存在“正在播放”的控制器
  ///
  /// - 已初始化、正在播放且无错误的任一控制器即视为“分组在播”
  bool isPlaying(String groupId) {
    final set = _groups[groupId];
    if (set == null || set.isEmpty) return false;
    for (final c in List<VideoPlayerController>.from(set)) {
      try {
        if (c.value.isInitialized && c.value.isPlaying && !c.value.hasError) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 为分组注册页面策略委托
  ///
  /// - [clearOthersKeepCurrent]：清理除当前索引外的控制器缓存（为新页面让出内存）
  /// - [restoreWindow]：按页面策略恢复相邻位置缓存窗口（页面返回时恢复体验）
  void setDelegates(String groupId,
      {Future<void> Function()? clearOthersKeepCurrent,
      Future<void> Function()? restoreWindow}) {
    if (clearOthersKeepCurrent != null) {
      _clearOthersKeepCurrent[groupId] = clearOthersKeepCurrent;
    }
    if (restoreWindow != null) {
      _restoreWindowDelegates[groupId] = restoreWindow;
    }
  }

  /// 移除分组的策略委托
  ///
  /// - 页面销毁时调用，清理对应委托
  void removeDelegates(String groupId) {
    _clearOthersKeepCurrent.remove(groupId);
    _restoreWindowDelegates.remove(groupId);
  }

  /// 清理分组缓存但保留当前：让出内存给新页面
  ///
  /// - 触发分组注册的清理委托；仅当前控制器保留，其余全部释放
  Future<void> trimGroupMemoryKeepCurrent(String groupId) async {
    final fn = _clearOthersKeepCurrent[groupId];
    if (fn != null) {
      await fn();
    }
  }

  /// 恢复分组的相邻窗口：页面回退后恢复原策略
  ///
  /// - 触发分组注册的窗口恢复委托；根据页面策略恢复邻居缓存
  Future<void> restoreGroupWindow(String groupId) async {
    final fn = _restoreWindowDelegates[groupId];
    if (fn != null) {
      await fn();
    }
  }

  Future<void> pauseAllExcept(VideoPlayerController keep) async {
    for (final set in _groups.values) {
      for (final c in List<VideoPlayerController>.from(set)) {
        if (identical(c, keep)) continue;
        try {
          if (c.value.isInitialized && c.value.isPlaying) {
            await c.pause();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> playExclusive(String groupId, VideoPlayerController controller) async {
    await pauseAllExcept(controller);
    try {
      if (controller.value.isInitialized && !controller.value.hasError && !controller.value.isPlaying) {
        await controller.play();
      }
    } catch (_) {}
    setCurrent(groupId, controller);
  }
}
