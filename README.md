# flutter_video_feed_list 插件说明（中文）

## 简介
- 提供短视频信息流页面组件 `VideoFeedView`，支持上下滑动翻页、滑到即播、低内存运行策略
- 视频显示采用 Cover（铺满且不变形），加载/缓冲/错误叠层统一管理
- 内置控制器窗口管理、并发防重与缓存驱逐（LRU/FIFO），减少纹理峰值与抖动
- 支持封面图片的邻近预加载，避免滑动时白屏

## 安装与引入
- 在应用的 `pubspec.yaml` 中添加依赖后，引入：

```dart
import 'package:flutter_video_feed_list/flutter_video_feed_list.dart';
```

## 快速上手
```dart
final items = <VideoItem>[
  VideoItem(
    videoUrl: 'https://example.com/video1.mp4',
    coverUrl: 'https://example.com/cover1.jpg',
    id: 'v1',
  ),
  // ... 更多条目
];

VideoFeedView(
  items: items,
  autoplay: true,
  loop: true,
  // 建议：慢滑邻居 1，快滑仅当前
  preloadAround: 1,
  maxCacheControllers: 2,
  // 建议：启用封面预加载
  preloadCoverAround: 2,
  // 建议：去掉稳态延时以“滑到即播”
  settleDelayMs: 0,
  showControllerOnlyOnCurrentPage: true,
  aggressiveOnFastScroll: true,
  // 低内存设备建议开启 Eco
  ecoMode: true,
  enableLogs: true,
)
```

## 参数说明
- `items`：视频/封面数据源列表（`List<VideoItem>`）
- `initialIndex`：初始展示的逻辑索引（默认 0）
- `loop`：是否循环播放当前视频（默认 true）
- `autoplay`：是否自动播放（初始化完成后立即播放，默认 true）
- `preloadAround`：邻近页控制器预初始化数量（慢滑建议 1）
- `preloadCoverAround`：邻近页封面预加载数量，避免滑动时白屏（建议 2）
- `maxCacheControllers`：控制器缓存上限，避免纹理/内存过高（建议 1–2）
- `settleDelayMs`：滚动结束到稳态的延迟（毫秒），“滑到即播”场景建议 0
- `infiniteScroll`：是否启用“近似无限”滚动（通过重复页实现，默认 true）
- `imageCacheMaxBytes`：全局图片缓存上限（字节），控制封面占用（默认 32MB）
- `showControllerOnlyOnCurrentPage`：仅当前页渲染控制器，其他页只显示封面，降低纹理占用（默认 true）
- `onIndexChanged`：页索引变化回调（逻辑索引）
- `aggressiveOnFastScroll`：快滑时激进清理，仅保留当前页控制器（默认 true）
- `enableLogs`：开启诊断日志输出（默认 false）
- `evictionPolicy`：控制器驱逐策略（`EvictionPolicy.lru|fifo`，默认 lru）
- `ecoMode`：生态模式（仅当前页、禁预加载），进一步降低内存（默认 false）
- `maxControllersEco`：生态模式下的控制器上限（建议 1）
- `preloadAroundEco`：生态模式下的邻居预加载数量（建议 0）

## 内存与体验优化建议
- 控制器数量策略：
  - 慢滑：保留当前+邻居 1；快滑：仅当前页
  - 低内存设备与激烈交互下建议开启 `ecoMode: true`
- 并发防重与预驱逐：
  - 同一 key 的创建会复用进行中的 Future，避免重复创建
  - 创建前按 LRU/FIFO 预驱逐 1 个缓存项，避免“先创建再回收”的内存峰值
- 封面优化：
  - 启用 `preloadCoverAround`，并根据父容器与设备像素比进行尺寸预估，减少白屏与过度内存占用
  - 封面使用低质量与限制尺寸（组件内部已按 `ResizeImage` 预估尺寸）
- 资源侧建议：
  - 使用 HLS/DASH 多码率源或转码到适配分辨率（如 720p/1080p），显著降低纹理占用

## 音量控制
- 最低音量：`kMutedVolume = 0.001`
- 全局函数：
```dart
import 'package:flutter_video_feed_list/flutter_video_feed_list.dart';

changeVideoVolume(0.5); // 设置所有视频音量为 0.5
changeVideoVolume(0);   // 会被提升到 0.001，避免完全静音问题
```
- 当前播放与后续初始化的视频都会实时生效。

## 业务叠层（bizWidgets）
- 通过 `bizWidgetsBuilder` 为每个条目提供覆盖在视频之上的自定义组件：
```dart
VideoFeedView(
  items: items,
  bizWidgetsBuilder: (context, item, index) => [
    Positioned(
      left: 16,
      top: 48,
      child: CircleAvatar(radius: 20),
    ),
    Positioned(
      right: 16,
      bottom: 80,
      child: Column(children: [
        Icon(Icons.favorite, color: Colors.red),
        Text('1234'),
      ]),
    ),
  ],
)
```

## 示例配置（顺畅与低内存）
```dart
VideoFeedView(
  items: items,
  autoplay: true,
  loop: true,
  preloadAround: 1,
  preloadCoverAround: 2,
  maxCacheControllers: 2,
  settleDelayMs: 0,
  ecoMode: true,
  showControllerOnlyOnCurrentPage: true,
  aggressiveOnFastScroll: true,
  enableLogs: true,
)
```

## 代码结构
- `src/models/video_item.dart`：实体类；中文注释说明字段语义
- `src/enums/eviction_policy.dart`：缓存驱逐策略枚举（LRU/FIFO）
- `src/services/window_manager.dart`：窗口保留策略（当前+邻居、清理与初始化）
- `src/widgets/video_feed_view.dart`：主视图组件（滑到即播、参数接入）
- `src/widgets/video_player_tile.dart`：单条播放组件（FittedBox Cover 渲染与轻量叠层）
- `src/utils/logging.dart`：受开关控制的日志输出

## 变更日志（本版本）
- 新增：`ecoMode/maxControllersEco/preloadAroundEco` 自适应运行参数
- 新增：`preloadCoverAround` 封面邻近预加载，提升滑动体验
- 拆分：models/enums/services/widgets/utils 分层与中文注释完善
- 优化：滑到即播、快滑仅当前、并发防重与容量预驱逐
