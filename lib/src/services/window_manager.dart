// 控制器窗口策略：优先下一条，先就绪当前页，再按许可初始化邻居。
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../utils/logging.dart';

/// 非循环列表优先下一条且不环绕；循环列表保留既有的前邻居优先顺序。
Set<String> controllerKeysForWindow({
  required List<IVideoItem> items,
  required int currentIndex,
  required int maxCacheControllers,
  bool infiniteScroll = true,
}) {
  if (items.isEmpty) return <String>{};
  final maxKeep = maxCacheControllers.clamp(1, items.length);
  final keys = <String>{};
  void add(int index) {
    if (keys.length >= maxKeep) return;
    if (!infiniteScroll && (index < 0 || index >= items.length)) return;
    keys.add(items[(index % items.length + items.length) % items.length].key);
  }

  add(currentIndex);
  for (var distance = 1;
      distance < items.length && keys.length < maxKeep;
      distance++) {
    if (infiniteScroll) {
      add(currentIndex - distance);
      add(currentIndex + distance);
    } else {
      add(currentIndex + distance);
      add(currentIndex - distance);
    }
  }
  return keys;
}

/// 过期任务在每次 await 后退出，不继续释放或创建新窗口的控制器。
Future<void> manageControllerWindow({
  required List<IVideoItem> items,
  required int currentIndex,
  required int maxCacheControllers,
  required Map<String, VideoPlayerController> controllerCache,
  required Future<void> Function(String key) removeController,
  required Future<VideoPlayerController?> Function(IVideoItem item)
      getOrCreateController,
  bool infiniteScroll = true,
  bool initializeNeighbors = true,
  bool Function()? shouldContinue,
}) async {
  if (items.isEmpty || shouldContinue?.call() == false) return;
  final keysToKeep = controllerKeysForWindow(
    items: items,
    currentIndex: currentIndex,
    maxCacheControllers: maxCacheControllers,
    infiniteScroll: infiniteScroll,
  );
  final keysToDispose =
      controllerCache.keys.where((key) => !keysToKeep.contains(key)).toList();
  for (final key in keysToDispose) {
    if (shouldContinue?.call() == false) return;
    await removeController(key);
  }
  for (final key in keysToKeep) {
    if (shouldContinue?.call() == false) return;
    await getOrCreateController(items.firstWhere((item) => item.key == key));
    if (!initializeNeighbors) break;
  }
  logging(
      'window keep=${keysToKeep.length} active=${controllerCache.length} neighbors=$initializeNeighbors');
}
