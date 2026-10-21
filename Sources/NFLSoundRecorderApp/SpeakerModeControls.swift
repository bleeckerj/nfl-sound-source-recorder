import SwiftUI

struct SpeakerModeControls: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open speakers: echo cancellation", isOn: $controller.speakerMode)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(controller.isRecording)
            if controller.speakerMode {
                Text("Use the built-in Mac speakers and microphone. Select the call app above. Echo cancellation adapts over the first few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Original app and microphone tracks are kept beside the mix (about 46 MB/min).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
