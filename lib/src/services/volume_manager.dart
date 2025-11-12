import 'dart:async';

/// 最低音量阈值（避免完全静音在部分设备产生异常表现）
const double kMutedVolume = 0.001;

/// 全局音量管理器
///
/// - 管理并广播当前视频音量，范围 [kMutedVolume, 1.0]
/// - 业务可调用 [changeVideoVolume] 修改音量，所有已初始化控制器实时生效
class VolumeManager {
  VolumeManager._();
  static final VolumeManager instance = VolumeManager._();

  /// 音量变更广播（所有订阅者收到最新值）
  final StreamController<double> _controller =
      StreamController<double>.broadcast();

  /// 当前音量（默认 1.0）
  double _volume = 1.0;

  /// 当前音量值
  double get volume => _volume;

  /// 音量流（订阅后可在控件或服务内同步更新）
  Stream<double> get stream => _controller.stream;

  /// 修改全局音量并广播
  ///
  /// - 入参范围建议 0–1；小于等于 0 统一提升为 [kMutedVolume]
  /// - 超过 1 按 1.0 处理；与当前值一致时不广播
  void change(double v) {
    double nv = v;
    if (nv <= 0) {
      nv = kMutedVolume;
    } else if (nv < kMutedVolume) {
      nv = kMutedVolume;
    } else if (nv > 1.0) {
      nv = 1.0;
    }
    if (nv == _volume) return;
    _volume = nv;
    _controller.add(_volume);
  }
}

/// 业务调用入口：修改全局音量
void changeVideoVolume(double v) => VolumeManager.instance.change(v);
