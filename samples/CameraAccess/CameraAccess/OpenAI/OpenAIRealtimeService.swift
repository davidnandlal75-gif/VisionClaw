import Foundation
import UIKit

enum OpenAIConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

@MainActor
class OpenAIRealtimeService: ObservableObject {
  @Published var connectionState: OpenAIConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?
  var onOutputTranscription: ((String) -> Void)?
  var onToolCall: ((OpenAIFunctionCall) -> Void)?

  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var connectContinuation: CheckedContinuation<Bool, Never>?
  private let delegate = OpenAIWebSocketDelegate()
  private var urlSession: URLSession!
  private let sendQueue = DispatchQueue(label: "openai.send", qos: .userInitiated)

  // Track in-progress function calls for argument accumulation
  private var pendingFunctionCalls: [String: (name: String, arguments: String)] = [:]

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  func connect() async -> Bool {
    guard let url = OpenAIConfig.websocketURLWithModel() else {
      connectionState = .error("No API key configured")
      return false
    }

    connectionState = .connecting

    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.connectContinuation = continuation

      self.delegate.onOpen = { [weak self] protocol_ in
        guard let self else { return }
        Task { @MainActor in
          self.connectionState = .settingUp
          self.startReceiving()
        }
      }

      self.delegate.onClose = { [weak self] code, reason in
        guard let self else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .disconnected
          self.isModelSpeaking = false
          self.onDisconnected?("Connection closed (code \(code.rawValue): \(reasonStr))")
        }
      }

      self.delegate.onError = { [weak self] error in
        guard let self else { return }
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .error(msg)
          self.isModelSpeaking = false
          self.onDisconnected?(msg)
        }
      }

      var request = URLRequest(url: url)
      request.setValue("Bearer \(OpenAIConfig.apiKey)", forHTTPHeaderField: "Authorization")
      request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

      self.webSocketTask = self.urlSession.webSocketTask(with: request)
      self.webSocketTask?.resume()

      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
    }

    return result
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onToolCall = nil
    connectionState = .disconnected
    isModelSpeaking = false
    pendingFunctionCalls.removeAll()
    resolveConnect(success: false)
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let base64 = data.base64EncodedString()
      let json: [String: Any] = [
        "type": "input_audio_buffer.append",
        "audio": base64
      ]
      self?.sendJSON(json)
    }
  }

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      guard let jpegData = image.jpegData(compressionQuality: AppConfig.videoJPEGQuality) else { return }
      let base64 = jpegData.base64EncodedString()
      let json: [String: Any] = [
        "type": "conversation.item.create",
        "item": [
          "type": "message",
          "role": "user",
          "content": [
            [
              "type": "input_image",
              "image_url": "data:image/jpeg;base64,\(base64)"
            ] as [String: Any]
          ]
        ] as [String: Any]
      ]
      self?.sendJSON(json)
    }
  }

  func sendToolResponse(callId: String, output: String) {
    sendQueue.async { [weak self] in
      let createItem: [String: Any] = [
        "type": "conversation.item.create",
        "item": [
          "type": "function_call_output",
          "call_id": callId,
          "output": output
        ] as [String: Any]
      ]
      self?.sendJSON(createItem)

      let createResponse: [String: Any] = [
        "type": "response.create"
      ]
      self?.sendJSON(createResponse)
    }
  }

  // MARK: - Private

  private func resolveConnect(success: Bool) {
    if let cont = connectContinuation {
      connectContinuation = nil
      cont.resume(returning: success)
    }
  }

  private func sendSessionUpdate() {
    let tools: [[String: Any]] = ToolDeclarations.allDeclarations().map { decl in
      var tool: [String: Any] = [
        "type": "function",
        "name": decl["name"] as? String ?? ""
      ]
      if let desc = decl["description"] as? String {
        tool["description"] = desc
      }
      if let params = decl["parameters"] as? [String: Any] {
        tool["parameters"] = params
      }
      return tool
    }

    let sessionUpdate: [String: Any] = [
      "type": "session.update",
      "session": [
        "modalities": ["text", "audio"],
        "instructions": OpenAIConfig.systemInstruction,
        "voice": "alloy",
        "input_audio_format": "pcm16",
        "output_audio_format": "pcm16",
        "input_audio_transcription": [
          "model": "whisper-1"
        ] as [String: Any],
        "turn_detection": [
          "type": "server_vad",
          "threshold": 0.5,
          "prefix_padding_ms": 300,
          "silence_duration_ms": 500
        ] as [String: Any],
        "tools": tools,
        "tool_choice": "auto"
      ] as [String: Any]
    ]
    sendJSON(sessionUpdate)
  }

  private func sendJSON(_ json: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let string = String(data: data, encoding: .utf8) else {
      return
    }
    webSocketTask?.send(.string(string)) { _ in }
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            await self.handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              await self.handleMessage(text)
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            await MainActor.run {
              self.resolveConnect(success: false)
              self.connectionState = .disconnected
              self.isModelSpeaking = false
              self.onDisconnected?(reason)
            }
          }
          break
        }
      }
    }
  }

  private func handleMessage(_ text: String) async {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
      return
    }

    switch type {
    case "session.created":
      NSLog("[OpenAI] Session created")
      sendSessionUpdate()

    case "session.updated":
      NSLog("[OpenAI] Session updated — ready")
      connectionState = .ready
      resolveConnect(success: true)

    case "response.audio.delta":
      if let delta = json["delta"] as? String,
         let audioData = Data(base64Encoded: delta) {
        if !isModelSpeaking {
          isModelSpeaking = true
          if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
            let latency = Date().timeIntervalSince(speechEnd)
            NSLog("[Latency] %.0fms (user speech end -> first audio)", latency * 1000)
            responseLatencyLogged = true
          }
        }
        onAudioReceived?(audioData)
      }

    case "response.audio_transcript.delta":
      if let delta = json["delta"] as? String, !delta.isEmpty {
        onOutputTranscription?(delta)
      }

    case "conversation.item.input_audio_transcription.completed":
      if let transcript = json["transcript"] as? String, !transcript.isEmpty {
        NSLog("[OpenAI] You: %@", transcript)
        onInputTranscription?(transcript)
      }

    case "input_audio_buffer.speech_started":
      NSLog("[OpenAI] Speech started (VAD)")
      if isModelSpeaking {
        isModelSpeaking = false
        onInterrupted?()
      }

    case "input_audio_buffer.speech_stopped":
      lastUserSpeechEnd = Date()
      responseLatencyLogged = false

    case "response.function_call_arguments.delta":
      if let callId = json["call_id"] as? String,
         let delta = json["delta"] as? String {
        if let existing = pendingFunctionCalls[callId] {
          pendingFunctionCalls[callId] = (existing.name, existing.arguments + delta)
        } else {
          let name = json["name"] as? String ?? ""
          pendingFunctionCalls[callId] = (name, delta)
        }
      }

    case "response.function_call_arguments.done":
      if let callId = json["call_id"] as? String {
        let name = json["name"] as? String ?? pendingFunctionCalls[callId]?.name ?? ""
        let arguments = json["arguments"] as? String ?? pendingFunctionCalls[callId]?.arguments ?? "{}"
        pendingFunctionCalls.removeValue(forKey: callId)
        NSLog("[OpenAI] Tool call: %@ (id: %@)", name, callId)
        let call = OpenAIFunctionCall(callId: callId, name: name, arguments: arguments)
        onToolCall?(call)
      }

    case "response.done":
      isModelSpeaking = false
      responseLatencyLogged = false
      onTurnComplete?()

    case "error":
      if let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        NSLog("[OpenAI] Error: %@", message)
        connectionState = .error(message)
      }

    default:
      break
    }
  }
}

// MARK: - WebSocket Delegate

private class OpenAIWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: ((String?) -> Void)?
  var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
  var onError: ((Error?) -> Void)?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?(`protocol`)
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    onClose?(closeCode, reason)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      onError?(error)
    }
  }
}
