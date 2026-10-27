// 原生播放器旁路采样，所有音频仍由原播放器正常输出。
import AVFoundation
import CoreImage
import MediaToolbox
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif

private final class MotionAudioPower {
  private let lock = NSLock()
  var format = AudioStreamBasicDescription()
  private var enabled = true
  private var square = 0.0
  private var count = 0
  private var lastWindow = ProcessInfo.processInfo.systemUptime
  private var duty = 0
  private var sampledAt = 0.0
  func setEnabled(_ value: Bool) { lock.lock(); enabled=value; duty=0; sampledAt=0; lock.unlock() }
  func sample() -> (Int, Bool) {
    lock.lock(); defer { lock.unlock() }
    return (duty, sampledAt > 0 && ProcessInfo.processInfo.systemUptime-sampledAt < 0.6)
  }
  func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    lock.lock(); defer { lock.unlock() }
    guard enabled else { return }
    let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    for buffer in UnsafeMutableAudioBufferListPointer(list) {
      guard let data = buffer.mData else { continue }
      let n = Int(buffer.mDataByteSize) / max(1, Int(format.mBitsPerChannel / 8))
      if isFloat && format.mBitsPerChannel == 32 {
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<n { let value=Double(samples[i]); if value.isFinite {square+=value*value;count+=1} }
      } else if format.mBitsPerChannel == 16 {
        let samples = data.assumingMemoryBound(to: Int16.self)
        for i in 0..<n { let value=Double(samples[i])/32768; square+=value*value;count+=1 }
      }
    }
    let now=ProcessInfo.processInfo.systemUptime
    if now-lastWindow >= 0.1 && count > 0 {
      let rms=sqrt(square/Double(count)); let db=rms > 0 ? 20*log10(rms) : -160
      duty=Int(max(0,min(100,(db+60)/60*100)).rounded())
      sampledAt=now; lastWindow=now; square=0;count=0
    }
  }
}

@MainActor
final class MotionPlayerSampler {
  private weak var owner: VideoPlayer?
  private let power=MotionAudioPower()
  private var tap: MTAudioProcessingTap?
  private var installing=false
  private var audioAbsent=false
  private let imageContext=CIContext(options: [.cacheIntermediates: false])
  init(owner: VideoPlayer) { self.owner=owner }
  func stop() { power.setEnabled(false) }
  private func installTap() {
    guard !audioAbsent, tap == nil, !installing, let item=owner?.player.currentItem else { return }
    installing=true
    item.asset.loadTracks(withMediaType: .audio) { [weak self, weak item] tracks, _ in
      DispatchQueue.main.async {
        guard let self, let item, self.owner?.player.currentItem === item else { return }
        self.installing=false
        guard let track=tracks?.first else { self.audioAbsent=true; return }
        let context=Unmanaged.passRetained(self.power).toOpaque()
        var callbacks=MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: context,
          init: { _, clientInfo, storage in storage.pointee=clientInfo },
          finalize: { tap in Unmanaged<MotionAudioPower>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
          prepare: { tap, _, format in
            let p=Unmanaged<MotionAudioPower>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            p.format=format.pointee
          }, unprepare: { _ in },
          process: { tap, frames, flags, buffers, framesOut, flagsOut in
            let status=MTAudioProcessingTapGetSourceAudio(tap,frames,buffers,flagsOut,nil,framesOut)
            guard status == noErr else { framesOut.pointee=0; return }
            let p=Unmanaged<MotionAudioPower>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            p.consume(buffers,frames:Int(framesOut.pointee))
          })
        var reference: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault,&callbacks,kMTAudioProcessingTapCreationFlag_PostEffects,&reference) == noErr,
          let created=reference else { Unmanaged<MotionAudioPower>.fromOpaque(context).release(); return }
        let parameters=AVMutableAudioMixInputParameters(track:track)
        parameters.audioTapProcessor=created
        let mix=AVMutableAudioMix(); mix.inputParameters=[parameters]
        self.tap=created; item.audioMix=mix
      }
    }
  }
  func sample(includeFrame: Bool, result: @escaping FlutterResult) {
    guard let owner, !owner.disposed else { result(FlutterError(code:"player_unavailable",message:nil,details:nil));return }
    power.setEnabledIfNeeded()
    installTap()
    let (duty,fresh)=power.sample()
    var output:[String:Any]=["audioAvailable":fresh,"audioDuty":duty,"positionMs":owner.player.currentTime().seconds.isFinite ? owner.player.currentTime().seconds*1000 : 0,"capturedAtMs":Date().timeIntervalSince1970*1000,"playing":owner.isPlaying]
    guard includeFrame else { result(output); return }
    // Texture 使用引擎已取到的最新帧；PlatformView 直接读取 AVPlayerItemVideoOutput。
    let buffer: CVPixelBuffer?
    if let texture=owner as? TextureBasedVideoPlayer {
      let frame=texture.motionSample()
      buffer=frame?.0
      if let capturedAt=frame?.1 { output["frameCapturedAtMs"]=capturedAt }
    }
    else { buffer=owner.pixelBufferSource.copyPixelBuffer(forItemTime:owner.player.currentTime(),itemTimeForDisplay:nil) }
    guard let buffer else { result(output); return }
    var image=CIImage(cvPixelBuffer:buffer)
    let transform=owner.motionTransform
    image=image.transformed(by:transform)
    let scale=min(1,480/max(image.extent.width,image.extent.height))
    image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
    #if os(iOS)
    if let cg=imageContext.createCGImage(image,from:image.extent), let jpeg=UIImage(cgImage:cg).jpegData(compressionQuality:0.7) {
      output["bytes"]=FlutterStandardTypedData(bytes:jpeg);output["videoAvailable"]=true
    }
    #endif
    result(output)
  }
}

private extension MotionAudioPower {
  func setEnabledIfNeeded() { lock.lock(); enabled=true; lock.unlock() }
}
