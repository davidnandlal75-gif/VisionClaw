import Foundation

enum AIProvider: String, CaseIterable {
  case gemini
  case openai

  var displayName: String {
    switch self {
    case .gemini: return "Gemini"
    case .openai: return "OpenAI"
    }
  }

  var inputSampleRate: Double {
    switch self {
    case .gemini: return 16000
    case .openai: return 24000
    }
  }

  var outputSampleRate: Double {
    return 24000
  }

  static var saved: AIProvider {
    get {
      let raw = UserDefaults.standard.string(forKey: "selectedAIProvider") ?? ""
      return AIProvider(rawValue: raw) ?? .gemini
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: "selectedAIProvider")
    }
  }
}
