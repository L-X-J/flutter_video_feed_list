import 'package:video_player/video_player.dart';
import '../models/video_item.dart';

/// 窗口控制：在当前索引附近保留有限数量的控制器
///
/// - [items] 数据源列表
/// - [currentIndex] 当前逻辑索引（用于计算邻居）
/// - [maxCacheControllers] 控制器上限（含当前）
/// - [controllerCache] 控制器缓存映射（key -> controller）
/// - [removeController] 移除控制器的回调（含资源释放）
/// - [getOrCreateController] 获取或创建控制器的回调
/// - [enableLogs] 是否输出诊断日志
Future<void> manageControllerWindow({
  required List<IVideoItem> items,
  required int currentIndex,
  required int maxCacheControllers,
  required Map<String, VideoPlayerController> controllerCache,
  required Future<void> Function(String key) removeController,
  required Future<VideoPlayerController?> Function(IVideoItem item)
      getOrCreateController,
  bool enableLogs = false,
}) async {
  if (items.isEmpty) return;
  final keysToKeep = <String>{};
  int wrap(int i) => (i % items.length + items.length) % items.length;
  final centerKey = items[wrap(currentIndex)].key;
  keysToKeep.add(centerKey);

  int left = currentIndex - 1;
  int right = currentIndex + 1;
  while (keysToKeep.length < maxCacheControllers &&
      (left >= 0 || right < items.length)) {
    if (left >= -items.length) {
      keysToKeep.add(items[wrap(left)].key);
      left--;
      if (keysToKeep.length >= maxCacheControllers) break;
    }
    if (right < items.length * 2) {
      keysToKeep.add(items[wrap(right)].key);
      right++;
    }
  }

  // 超出保留集合的控制器全部释放
  final keysToDispose =
      controllerCache.keys.where((id) => !keysToKeep.contains(id)).toList();
  for (final id in keysToDispose) {
    await removeController(id);
  }

  // 先初始化当前页控制器
  await getOrCreateController(items[wrap(currentIndex)]);

  // 再初始化邻居控制器：按距离近的优先
  final remainingIndices = <int>[];
  for (int i = 1; i <= maxCacheControllers; i++) {
    final li = currentIndex - i;
    final ri = currentIndex + i;
    if (keysToKeep.contains(items[wrap(li)].key)) {
      remainingIndices.add(wrap(li));
    }
    if (keysToKeep.contains(items[wrap(ri)].key)) {
      remainingIndices.add(wrap(ri));
    }
  }
  for (final idx in remainingIndices) {
    await getOrCreateController(items[idx]);
  }
  if (enableLogs) {
    // ignore: avoid_print
    print('window keep=${keysToKeep.length} active=${controllerCache.length}');
  }
}
