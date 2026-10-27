// 播放器 PCM 旁路功率计算，原样转交所有音频字节。
package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.SystemClock;
import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Map;
import java.util.WeakHashMap;

@UnstableApi
public final class MotionAudioProcessor extends BaseAudioProcessor {
  private static final Map<ExoPlayer, MotionAudioProcessor> PROCESSORS = new WeakHashMap<>();
  public volatile boolean enabled;
  public volatile int duty;
  public volatile long lastSampleAt;
  private double sumSquares;
  private int count;

  public static ExoPlayer build(ExoPlayer.Builder builder, Context context) {
    MotionAudioProcessor processor = new MotionAudioProcessor();
    builder.setRenderersFactory(new DefaultRenderersFactory(context) {
      @Override protected AudioSink buildAudioSink(Context c, boolean enableFloatOutput, boolean enablePlaybackParams) {
        return new DefaultAudioSink.Builder(c).setAudioProcessors(new AudioProcessor[] {processor}).build();
      }
    });
    ExoPlayer player = builder.build();
    PROCESSORS.put(player, processor);
    return player;
  }
  public static MotionAudioProcessor of(ExoPlayer player) { return PROCESSORS.get(player); }
  @Override protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
    if (format.encoding != C.ENCODING_PCM_16BIT && format.encoding != C.ENCODING_PCM_FLOAT) return AudioFormat.NOT_SET;
    return format;
  }
  @Override public void queueInput(ByteBuffer input) {
    int size = input.remaining();
    if (enabled) {
      ByteBuffer samples = input.asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN);
      while (samples.remaining() >= (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT ? 4 : 2)) {
        double v = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT ? samples.getFloat() : samples.getShort() / 32768.0;
        if (Double.isFinite(v)) { sumSquares += v*v; count++; }
      }
      long now = SystemClock.elapsedRealtime();
      if (now-lastSampleAt >= 100 && count > 0) {
        double rms = Math.sqrt(sumSquares/count);
        double db = rms > 0 ? 20*Math.log10(rms) : -160;
        duty = (int)Math.round(Math.max(0, Math.min(100, (db + 60)/60*100)));
        lastSampleAt = now;
        sumSquares = 0; count = 0;
      }
    } else { duty=0; sumSquares=0; count=0; }
    ByteBuffer output = replaceOutputBuffer(size);
    // input 和 output 可能指向同一底层 DirectByteBuffer；必须先复制再写入，
    // 否则 ByteBuffer.put(self) 会抛 IllegalArgumentException。
    if (output == input) {
      output.flip();
    } else {
      output.put(input).flip();
    }
  }
  @Override protected void onFlush() { duty=0; lastSampleAt=0; sumSquares=0; count=0; }
}
