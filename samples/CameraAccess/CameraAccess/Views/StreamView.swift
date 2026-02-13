/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling. Extended with AI assistant integration (Gemini or OpenAI).
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var sessionVM: RealtimeSessionViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // AI status overlay (top) + speaking indicator
      if sessionVM.isActive {
        VStack {
          AIStatusBar(sessionVM: sessionVM)
          Spacer()

          VStack(spacing: 8) {
            if !sessionVM.userTranscript.isEmpty || !sessionVM.aiTranscript.isEmpty {
              TranscriptView(
                userText: sessionVM.userTranscript,
                aiText: sessionVM.aiTranscript
              )
            }

            ToolCallStatusView(status: sessionVM.toolCallStatus)

            if sessionVM.isModelSpeaking {
              HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                  .foregroundColor(.white)
                  .font(.system(size: 14))
                SpeakingIndicator()
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(20)
            }
          }
          .padding(.bottom, 80)
        }
        .padding(.all, 24)
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, sessionVM: sessionVM)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
        if sessionVM.isActive {
          sessionVM.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    // AI error alert
    .alert("AI Assistant", isPresented: Binding(
      get: { sessionVM.errorMessage != nil },
      set: { if !$0 { sessionVM.errorMessage = nil } }
    )) {
      Button("OK") { sessionVM.errorMessage = nil }
    } message: {
      Text(sessionVM.errorMessage ?? "")
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var sessionVM: RealtimeSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button (glasses mode only — DAT SDK capture)
      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
      }

      // AI button
      CircleButton(
        icon: sessionVM.isActive ? "waveform.circle.fill" : "waveform.circle",
        text: "AI"
      ) {
        Task {
          if sessionVM.isActive {
            sessionVM.stopSession()
          } else {
            await sessionVM.startSession()
          }
        }
      }
    }
  }
}
