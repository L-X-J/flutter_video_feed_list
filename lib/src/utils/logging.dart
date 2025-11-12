/// 受开关控制的日志输出
void logIf(bool enable, String message) {
  if (!enable) return;
  // ignore: avoid_print
  print(message);
}
