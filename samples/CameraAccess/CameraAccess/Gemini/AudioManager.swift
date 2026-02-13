import AVFoundation
import Foundation

class AudioManager {
  var onAudioCaptured: ((Data) -> Void)?

  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private var isCapturing = false

  private let inputSampleRate: Double
  private let outputSampleRate: Double
  private let audioChannels: UInt32 = 1
  private let audioBitsPerSample: UInt32 = 16

  private let outputFormat: AVAudioFormat

  // Accumulate resampled PCM into ~100ms chunks before sending
  private let sendQueue = DispatchQueue(label: "audio.accumulator")
  private var accumulatedData = Data()
  private let minSendBytes: Int  // 100ms at inputSampleRate mono Int16

  init(inputSampleRate: Double = GeminiConfig.inputAudioSampleRate,
       outputSampleRate: Double = GeminiConfig.outputAudioSampleRate) {
    self.inputSampleRate = inputSampleRate
    self.outputSampleRate = outputSampleRate
    self.minSendBytes = Int(inputSampleRate * 0.1) * 2  // 100ms * 2 bytes per sample
    self.outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: outputSampleRate,
      channels: audioChannels,
      interleaved: true
    )!
  }

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
    let session = AVAudioSession.sharedInstance()
    // iPhone mode: voiceChat for aggressive echo cancellation (mic + speaker co-located)
    // Glasses mode: videoChat for mild AEC (mic is on glasses, speaker is on phone)
    let mode: AVAudioSession.Mode = useIPhoneMode ? .voiceChat : .videoChat
    try session.setCategory(
      .playAndRecord,
      mode: mode,
      options: [.defaultToSpeaker, .allowBluetooth]
    )
    try session.setPreferredSampleRate(inputSampleRate)
    try session.setPreferredIOBufferDuration(0.064)
    try session.setActive(true)
    NSLog("[Audio] Session mode: %@, input rate: %.0f, output rate: %.0f",
          useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)",
          inputSampleRate, outputSampleRate)
  }

  func startCapture() throws {
    guard !isCapturing else { return }

    audioEngine.attach(playerNode)
    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: outputSampleRate,
      channels: audioChannels,
      interleaved: false
    )!
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

    let inputNode = audioEngine.inputNode
    let inputNativeFormat = inputNode.outputFormat(forBus: 0)

    NSLog("[Audio] Native input format: %@ sampleRate=%.0f channels=%d",
          inputNativeFormat.commonFormat == .pcmFormatFloat32 ? "Float32" :
          inputNativeFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Other",
          inputNativeFormat.sampleRate, inputNativeFormat.channelCount)

    // Always tap in native format (Float32) and convert to Int16 PCM manually.
    // AVAudioEngine taps don't reliably convert between sample formats inline.
    let needsResample = inputNativeFormat.sampleRate != inputSampleRate
        || inputNativeFormat.channelCount != audioChannels

    NSLog("[Audio] Needs resample: %@", needsResample ? "YES" : "NO")

    sendQueue.async { self.accumulatedData = Data() }

    var converter: AVAudioConverter?
    if needsResample {
      let resampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputSampleRate,
        channels: audioChannels,
        interleaved: false
      )!
      converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
    }

    let capturedInputRate = inputSampleRate
    let capturedMinSendBytes = minSendBytes

    var tapCount = 0
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
      guard let self else { return }

      tapCount += 1
      let pcmData: Data

      if let converter {
        let resampleFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: capturedInputRate,
          channels: self.audioChannels,
          interleaved: false
        )!
        guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
          if tapCount <= 3 { NSLog("[Audio] Resample failed for tap #%d", tapCount) }
          return
        }
        pcmData = self.float32BufferToInt16Data(resampled)
      } else {
        pcmData = self.float32BufferToInt16Data(buffer)
      }

      // Accumulate into ~100ms chunks before sending
      self.sendQueue.async {
        self.accumulatedData.append(pcmData)
        if self.accumulatedData.count >= capturedMinSendBytes {
          let chunk = self.accumulatedData
          self.accumulatedData = Data()
          if tapCount <= 3 {
            let bytesPerMs = Int(capturedInputRate) * 2 / 1000
            NSLog("[Audio] Sending chunk: %d bytes (~%dms)",
                  chunk.count, bytesPerMs > 0 ? chunk.count / bytesPerMs : 0)
          }
          self.onAudioCaptured?(chunk)
        }
      }
    }

    try audioEngine.start()
    playerNode.play()
    isCapturing = true
  }

  func playAudio(data: Data) {
    guard isCapturing, !data.isEmpty else { return }

    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: outputSampleRate,
      channels: audioChannels,
      interleaved: false
    )!

    let frameCount = UInt32(data.count) / (audioBitsPerSample / 8 * audioChannels)
    guard frameCount > 0 else { return }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount

    guard let floatData = buffer.floatChannelData else { return }
    data.withUnsafeBytes { rawBuffer in
      guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
      for i in 0..<Int(frameCount) {
        floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
      }
    }

    playerNode.scheduleBuffer(buffer)
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  func stopPlayback() {
    playerNode.stop()
    playerNode.play()
  }

  func stopCapture() {
    guard isCapturing else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    playerNode.stop()
    audioEngine.stop()
    audioEngine.detach(playerNode)
    isCapturing = false
    // Flush any remaining accumulated audio
    sendQueue.async {
      if !self.accumulatedData.isEmpty {
        let chunk = self.accumulatedData
        self.accumulatedData = Data()
        self.onAudioCaptured?(chunk)
      }
    }
  }

  // MARK: - Private helpers

  private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return 0 }
    var sumSquares: Float = 0
    for i in 0..<frameCount {
      let s = floatData[0][i]
      sumSquares += s * s
    }
    return sqrt(sumSquares / Float(frameCount))
  }

  private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
    var int16Array = [Int16](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      let sample = max(-1.0, min(1.0, floatData[0][i]))
      int16Array[i] = Int16(sample * Float(Int16.max))
    }
    return int16Array.withUnsafeBufferPointer { ptr in
      Data(buffer: ptr)
    }
  }

  private func convertBuffer(
    _ inputBuffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
      return nil
    }

    var error: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if error != nil {
      return nil
    }

    return outputBuffer
  }
}
