import SwiftUI

struct ProviderPickerView: View {
  @Binding var selectedProvider: AIProvider

  var body: some View {
    Picker("AI Provider", selection: $selectedProvider) {
      ForEach(AIProvider.allCases, id: \.self) { provider in
        Text(provider.displayName).tag(provider)
      }
    }
    .pickerStyle(.segmented)
    .onChange(of: selectedProvider) { newValue in
      AIProvider.saved = newValue
    }
  }
}
