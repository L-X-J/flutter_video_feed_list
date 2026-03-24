## 现状与问题

* 当前在 `lib/src/video_feed_view.dart:476-484` 通过 `DefaultCacheManager.getSingleFile` 先完整下载到本地，再用 `VideoPlayerController.file` 播放，导致“下载完成后再播放”。

* 若文件路径初始化失败才回退到网络播放（`lib/src/video_feed_view.dart:506-527`），不符合“边播边缓存”的需求。

## 改造目标

* 当本地已缓存：仍直接走 `file` 播放以提升启动速度。

* 当本地未缓存：立即用 `networkUrl` 边播；同时在后台启动下载，将本次播放的网络数据并行写入缓存（下次可走 `file`）。

* 保持华为设备 `platformView` 的兼容选择（`lib/src/video_feed_view.dart:469-473`）。

## 设计方案

* 逻辑分支调整：

  * 先 `getFileFromCache(url)`，缓存命中则 `VideoPlayerController.file`。

  * 未命中则立刻 `VideoPlayerController.networkUrl(Uri.parse(url), viewType: effectiveViewType)`，并发启动缓存下载，不等待。

* 后台缓存下载：

  * 使用 `DefaultCacheManager().downloadFile(url)` 启动下载；为避免重复，新增 `_cacheDownloads: Map<String, Future<FileInfo?>>` 记录同一 `key` 的在途下载。

  * 下载完成后不需要热切换控制器；缓存用于下一次进入同一视频时的快速启动与节流。

* HLS/流媒体兼容：

  * 如 `videoUrl` 以 `.m3u8` 结尾或为流媒体源，跳过“整文件缓存”后台下载，仅使用 `networkUrl` 播放。

* 销毁与清理：

  * 在 `_removeController` 保持现有控制器释放流程；后台下载无需强制取消（CacheManager 无显式取消接口），释放不会受影响。

* 设备兼容：

  * 继续在 Android/Huawei 上优先选 `platformView`（`lib/src/video_feed_view.dart:469-473`），其余逻辑不变。

## 代码改动点（不引入新依赖）

1. 在 `_VideoFeedViewState` 内新增：

   * 字段 `_cacheDownloads = <String, Future<FileInfo?>>{}`。
2. 重写 `_createController(IVideoItem item)`：

   * 先查缓存命中走 `file`，否则：

     * 立即创建 `VideoPlayerController.networkUrl` 播放；

     * 触发 `DefaultCacheManager().downloadFile(item.videoUrl)`，将返回的 `Future` 存入 `_cacheDownloads[item.key]`，并在完成后清理该记录。

   * 保留原有 `volume/loop` 设置与 `register/touch/enforceCacheLimit` 调用。

   * 保留异常回退与 `platformView` 兜底分支。
3. 可选：对 `.m3u8`/流媒体源加简单判断，跳过后台整文件缓存。

## 验证步骤

* 运行 `fvm flutter analyze .` 确认静态检查通过。

* 首次进入某视频（缓存未命中）：观察画面能立即开始播放；同时打印日志确认后台缓存下载已启动。

* 再次进入同一视频：应直接命中缓存并走 `file` 控制器，启动更快且节省流量。

* 华为设备/Android：验证 `platformView` 路径仍能正常初始化与播放。

* 快速滑动与窗口管理：确保在 `manageControllerWindow` 流程下，控制器生命周期与缓存行为稳定。

## 风险与取舍

* 并行缓存会产生双倍网络下载（播放器与后台各一条），无法直接复用播放器的数据流；这是 `video_player` 的局限。若需真正“播放即写缓存”，后续可考虑：

  * Android 自定义 DataSource/ExoPlayer SimpleCache 的平台层封装；

  * 或迁移到支持内置缓存的播放器库（如 BetterPlayer 的缓存配置）。

## 交付内容

* 修改 `_createController` 的边播边缓存实现（不改动对外 API）。

* 保持现有日志与错误兜底，新增少量日志便于确认缓存后台下载启动/完成。

* 不引入新三方依赖与配置变更。

