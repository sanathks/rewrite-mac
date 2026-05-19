import Foundation

struct ResultMetadata: Equatable {
    let modelName: String
    let durationMs: Int
    let tokensPerSecond: Double
}

enum PopupPhase {
    case loading
    /// Live stream in progress. Text grows in place; buttons are disabled.
    case streaming(String, ResultMetadata)
    /// Final result. All buttons enabled.
    case result(String, ResultMetadata?)
    case error(String)
}

final class PopupState: ObservableObject {
    @Published var selectedModeId: UUID?
    @Published var modePhases: [UUID: PopupPhase] = [:]

    /// When generation started for each mode. Used to compute elapsed time
    /// when the result arrives.
    var loadingStartTimes: [UUID: Date] = [:]

    /// Per-mode chunk counter used to compute live tok/s during streaming.
    /// Cleared once the stream completes.
    var streamingTokenCounts: [UUID: Int] = [:]

    var modes: [RewriteMode]
    var onModeSelected: ((RewriteMode) -> Void)?
    /// Re-run generation for the currently-selected mode. Bypasses the result
    /// cache so the user can roll the dice again on the same prompt.
    var onRegenerate: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(modes: [RewriteMode]) {
        self.modes = modes
    }

    var currentPhase: PopupPhase {
        guard let id = selectedModeId else { return .loading }
        return modePhases[id] ?? .loading
    }
}
