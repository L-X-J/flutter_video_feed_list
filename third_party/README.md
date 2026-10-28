# 魔改 video_player 系列包

本目录是 video_player 定制版本的唯一维护位置。禁止修改 pub-cache。

| 包 | 基础版本 | 本库维护的差异 |
| --- | --- | --- |
| video_player | 2.14.1 | 公开只读 `nativePlayerId`，供宿主对当前活动播放器做媒体采样。 |
| video_player_android | 2.12.2 | 短视频缓冲参数（bufferForPlayback 500ms）；PCM 旁路功率（MotionAudioProcessor）及 Surface 的 PixelCopy 采样。 |
| video_player_avfoundation | 2.12.2 | preferredForwardBufferDuration=2s、automaticallyWaitsToMinimizeStalling=false；VideoOutput/纹理帧采样与 MTAudioProcessingTap。 |

来源为 Flutter packages 对应子包，每个包保留原 LICENSE 与 README。

## 宿主接入

pub 的 `dependency_overrides` 只在根项目生效，且其他依赖（如 `flutter_widget_from_html` → `chewie`）
会引入 pub.dev 上的同名包，因此宿主 App 必须同时声明：

```yaml
dependencies:
  flutter_video_feed_list:
    git:
      url: git@github.com:L-X-J/flutter_video_feed_list.git
      ref: <branch>

dependency_overrides:
  video_player:
    git: {url: git@github.com:L-X-J/flutter_video_feed_list.git, ref: <branch>, path: third_party/video_player}
  video_player_android:
    git: {url: git@github.com:L-X-J/flutter_video_feed_list.git, ref: <branch>, path: third_party/video_player_android}
  video_player_avfoundation:
    git: {url: git@github.com:L-X-J/flutter_video_feed_list.git, ref: <branch>, path: third_party/video_player_avfoundation}
```

三处 `ref` 必须一致。更新本目录后需验证宿主 App 的 Android 与 iOS 构建。
