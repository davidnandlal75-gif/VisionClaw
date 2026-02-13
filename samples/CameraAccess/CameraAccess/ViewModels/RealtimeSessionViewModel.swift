import Foundation
import SwiftUI

enum RealtimeConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

@MainActor
class RealtimeSessionViewModel: ObservableObject {
  @Published var isActive: Bool = false
  @Published var connectionState: RealtimeConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var provider: AIProvider = AIProvider.saved

  private var geminiService: GeminiLiveService?
  private var openAIService: OpenAIRealtimeService?
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private var audioManager: AudioManager?
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  var streamingMode: StreamingMode = .glasses

  var providerDisplayName: String {
    provider.displayName
  }

  func startSession() async {
    guard !isActive else { return }

    switch provider {
    case .gemini:
      guard GeminiConfig.isConfigured else {
        errorMessage = "Gemini API key not configured. Add your key to Secrets.swift"
        return
      }
    case .openai:
      guard OpenAIConfig.isConfigured else {
        errorMessage = "OpenAI API key not configured. Add your key to Secrets.swift"
        return
      }
    }

    isActive = true

    // Create AudioManager with correct sample rates for the selected provider
    let audio = AudioManager(
      inputSampleRate: provider.inputSampleRate,
      outputSampleRate: provider.outputSampleRate
    )
    audioManager = audio

    // Wire audio capture callback
    audio.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        if self.streamingMode == .iPhone && self.isModelSpeaking { return }
        switch self.provider {
        case .gemini:
          self.geminiService?.sendAudio(data: data)
        case .openai:
          self.openAIService?.sendAudio(data: data)
        }
      }
    }

    // Check OpenClaw connectivity
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    // Setup audio session
    do {
      try audio.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isActive = false
      return
    }

    // Connect to the selected provider
    var setupOk = false
    switch provider {
    case .gemini:
      setupOk = await startGeminiSession(audio: audio)
    case .openai:
      setupOk = await startOpenAISession(audio: audio)
    }

    if !setupOk {
      audioManager = nil
      toolCallRouter = nil
      isActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audio.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      stopSession()
      return
    }
  }

  func stopSession() {
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager?.stopCapture()
    audioManager = nil
    geminiService?.disconnect()
    geminiService = nil
    openAIService?.disconnect()
    openAIService = nil
    stateObservation?.cancel()
    stateObservation = nil
    isActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard isActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= AppConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now

    switch provider {
    case .gemini:
      geminiService?.sendVideoFrame(image: image)
    case .openai:
      openAIService?.sendVideoFrame(image: image)
    }
  }

  // MARK: - Gemini

  private func startGeminiSession(audio: AudioManager) async -> Bool {
    let service = GeminiLiveService()
    geminiService = service

    service.onAudioReceived = { [weak self] data in
      self?.audioManager?.playAudio(data: data)
    }

    service.onInterrupted = { [weak self] in
      self?.audioManager?.stopPlayback()
    }

    service.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = ""
      }
    }

    service.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    service.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    service.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    service.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService?.sendToolResponse(response)
          }
        }
      }
    }

    service.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.syncGeminiState(service)
      }
    }

    let setupOk = await service.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = service.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      service.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      return false
    }

    return true
  }

  private func syncGeminiState(_ service: GeminiLiveService) {
    switch service.connectionState {
    case .disconnected: connectionState = .disconnected
    case .connecting: connectionState = .connecting
    case .settingUp: connectionState = .settingUp
    case .ready: connectionState = .ready
    case .error(let msg): connectionState = .error(msg)
    }
    isModelSpeaking = service.isModelSpeaking
    toolCallStatus = openClawBridge.lastToolCallStatus
    openClawConnectionState = openClawBridge.connectionState
  }

  // MARK: - OpenAI

  private func startOpenAISession(audio: AudioManager) async -> Bool {
    let service = OpenAIRealtimeService()
    openAIService = service

    service.onAudioReceived = { [weak self] data in
      self?.audioManager?.playAudio(data: data)
    }

    service.onInterrupted = { [weak self] in
      self?.audioManager?.stopPlayback()
    }

    service.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = ""
      }
    }

    service.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = text
        self.aiTranscript = ""
      }
    }

    service.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    service.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    service.onToolCall = { [weak self] openAICall in
      guard let self else { return }
      Task { @MainActor in
        let geminiCall = openAICall.asGeminiFunctionCall()
        self.toolCallRouter?.handleToolCall(geminiCall) { [weak self] response in
          // Extract the result text from the Gemini-format response
          if let toolResponse = response["toolResponse"] as? [String: Any],
             let functionResponses = toolResponse["functionResponses"] as? [[String: Any]],
             let first = functionResponses.first,
             let responseValue = first["response"] as? [String: Any] {
            let output = (responseValue["result"] as? String)
              ?? (responseValue["error"] as? String)
              ?? "OK"
            self?.openAIService?.sendToolResponse(callId: openAICall.callId, output: output)
          }
        }
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.syncOpenAIState(service)
      }
    }

    let setupOk = await service.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = service.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to OpenAI"
      }
      errorMessage = msg
      service.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      return false
    }

    return true
  }

  private func syncOpenAIState(_ service: OpenAIRealtimeService) {
    switch service.connectionState {
    case .disconnected: connectionState = .disconnected
    case .connecting: connectionState = .connecting
    case .settingUp: connectionState = .settingUp
    case .ready: connectionState = .ready
    case .error(let msg): connectionState = .error(msg)
    }
    isModelSpeaking = service.isModelSpeaking
    toolCallStatus = openClawBridge.lastToolCallStatus
    openClawConnectionState = openClawBridge.connectionState
  }
}
