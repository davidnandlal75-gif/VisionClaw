import Foundation

struct OpenAIFunctionCall {
  let callId: String
  let name: String
  let arguments: String

  func asGeminiFunctionCall() -> GeminiFunctionCall {
    let args: [String: Any]
    if let data = arguments.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      args = parsed
    } else {
      args = ["task": arguments]
    }
    return GeminiFunctionCall(id: callId, name: name, args: args)
  }
}
