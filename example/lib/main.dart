import 'package:flutter/material.dart';
import 'package:flutter_video_feed_list/flutter_video_feed_list.dart';

void main() {
  runApp(const VideoFeedDemoApp());
}

/// 示例应用入口：演示视频信息流的基本用法
class VideoFeedDemoApp extends StatelessWidget {
  const VideoFeedDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Feed Demo',
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true),
      home: const VideoFeedDemoPage(),
    );
  }
}

/// 示例页面：构建数据并展示视频信息流组件
class VideoFeedDemoPage extends StatelessWidget {
  const VideoFeedDemoPage({super.key});

  /// 解析多行 `name,cover,video` 数据为 VideoItem 列表
  List<VideoItem<dynamic>> _parseUserData(String raw) {
    String clean(String s) => s
        .trim()
        .replaceAll('`', '')
        .replaceAll('“', '')
        .replaceAll('”', '')
        .replaceAll('’', '')
        .replaceAll('\u200b', '');

    final lines = raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final items = <VideoItem<dynamic>>[];
    for (final line in lines) {
      final parts = line.split(',');
      if (parts.length >= 3) {
        final name = clean(parts[0]);
        final cover = clean(parts[1]);
        final video = clean(parts[2]);
        if (cover.isNotEmpty && video.isNotEmpty) {
          items.add(
              VideoItem<dynamic>(videoUrl: video, coverUrl: cover, id: name));
        }
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    const raw =
        '@月月,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/49bb22388f194a2eb9d7c7e4d4106c71_20250729061546.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/4f3a128ef4f849d4a5f638dd93c1a066_20250811095544.mp4\n'
        '@莎莎,https://yuanqu-test.oss-cn-hangzhou.aliyuncs.com/public/common/96abf08e4e094353a07492d85a46d07d_20250717133055.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/616b729389924c8c988347f8be3a193e_20250811094517.mp4\n'
        '@瑶瑶,https://yuanqu-test.oss-cn-hangzhou.aliyuncs.com/public/common/11fe868ec92e4888972b470d8e023ff9_20250717113754.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/451439e50f5649d7b2b332ca3c0219d2_20250811094542.mp4\n'
        '@桥本奈绪,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/198383e20c0841ae924bf98d0f4af214_20250725071004.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/cf3b75c7f9bf4aae84d828b7a53c06cf_20250811094631.mp4\n'
        '@莲莲,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/dc18481fb8f743058c70a0c97ebd4811_20250725074507.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/c5bc3a8b5e4449828ac5c2b854bdd71a_20250811094726.mp4\n'
        '@神田優美,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/989c850eb89d42e29d9f3c37c444d76c_20250725082256.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/382c101ae57149f486690f5df14d23a3_20250811095923.mp4\n'
        '@朴恩静,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/2f112ddb2eba443da540b9361c7e3bcb_20250725094616.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/19134f6a9bb949cabe83822de19e0b6b_20250811095718.mp4\n'
        'u崽,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/1e87031ca75c46a29eb03e1aad0d46b2_20250731054845.png,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/15894c83d43b46108494ace21a242a06_20250811094822.mp4\n'
        '@伊娃,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/770375163771492188d73f86eca94d65_20250731071232.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/fdc36c6cc64346048e539f4056b72238_20250820021544.mp4\n'
        '墨兰,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/e65a0f0a008d4587987fa46bca484ed6_20250801081554.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/c37adbb077d949029105907bd1d6c7f9_20250811095143.mp4\n'
        '@凯拉玛,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/97d5d5cef4274d4e9bdd95fec647ad37_20250801093701.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/f1f19e3c3dba414786eb19dd3e9d31a5_20250811095328.mp4\n'
        '雪莉, `https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/37b6d7f8f4f34b518f60a88a8173a892_20250808055654.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/4b9822dd375e4d2eacca28541234b513_20250811095406.mp4`\n'
        '黎姬,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/1545be36ab7341dcb305271f2afdfda1_20250814032155.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/90afb1f034c349a9bd4c8325516ffced_20250820023134.mp4\n'
        '温晚, `https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/3f7ef8ccd9324771be1c376557e962f5_20250814084158.png,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/7bdf2f47d2b349889cb649182b66cb63_20250820020507.mp4`\n'
        '星野龙泽, `https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/92771885e48c418db488e582a9620c46_20250815082620.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/eb5e1016f22646d6b72327a21b3bf5bc_20250815092427.mp4`\n'
        '@娜娜, `https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/d1a76466bd5a467ea409e96786b8379e_20250901022326.png,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/a7b30107f550446d977c748ce57c0f71_20250901022316.mp4`\n'
        '莱娅・月藤,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/9006d41a53234f93bbe11b6841d4d839_20250901024701.png,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/e079af6ba0cf40ae9a1f19c6fbbf4f85_20250901024646.mp4\n'
        '@c酱,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/a2c6114994e140c18ab21a0c43107ca8_20250901024809.png,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/3455aa48655449f7a8b3c596888ec8c4_20250901024808.mp4\n'
        '@莎纱,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/01fdd7b987214f5684695737ca33ad64_20250916065551.jpg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/b48b9929d4c64e53904fba6b281b6bc6_20250916065556.mp4\n'
        '@悦悦,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/common/7389a4e7cde841c198f2a12aae2d884f_20250916075250.jpeg,https://yq-1363695004.cos.ap-shanghai.myqcloud.com/public/h264_video/c5f906fa0c98491393bbbfe933d7d49d_20250916075252.mp4';

    final items = _parseUserData(raw);
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        child: VideoFeedView(
          feedId: 'demo',
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
          viewType: VideoViewType.platformView,
          enableLogs: true,
          onIndexChanged: (i) {},
        ),
      ),
    );
  }
}
