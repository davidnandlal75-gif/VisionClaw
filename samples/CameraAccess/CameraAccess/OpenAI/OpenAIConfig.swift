import Foundation

enum OpenAIConfig {
  static let websocketURL = "wss://api.openai.com/v1/realtime"
  static let model = "gpt-realtime-2025-08-28"

  static let inputAudioSampleRate: Double = 24000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let apiKey = Secrets.openaiAPIKey

  static func websocketURLWithModel() -> URL? {
    guard isConfigured else { return nil }
    return URL(string: "\(websocketURL)?model=\(model)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_OPENAI_API_KEY" && !apiKey.isEmpty
  }

  static let systemInstruction = GeminiConfig.systemInstruction
}
