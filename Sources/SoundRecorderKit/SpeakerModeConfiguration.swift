import Foundation

/// Source requirements shared by the recorder and its controls, without opening audio devices.
public enum SpeakerModeConfiguration {
    public enum SelectionError: Swift.Error, LocalizedError, CustomStringConvertible {
        case appAudioRequired
        case microphoneRequired

        public var description: String {
            switch self {
            case .appAudioRequired:
                return "Speaker echo cancellation needs app audio. Under Record, choose the call app or All System Audio. For a microphone-only recording, turn off Open speakers."
            case .microphoneRequired:
                return "Speaker echo cancellation needs a microphone. Select the built-in Mac microphone under Microphone."
            }
        }

        public var errorDescription: String? { description }
    }

    public static func selectionError(hasAppAudio: Bool, hasMicrophone: Bool) -> SelectionError? {
        if !hasAppAudio { return .appAudioRequired }
        if !hasMicrophone { return .microphoneRequired }
        return nil
    }
}
