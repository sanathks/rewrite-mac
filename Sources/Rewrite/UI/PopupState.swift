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

    /// Wall-clock time the first chunk arrived for this mode. tok/s is
    /// measured from here, NOT from `loadingStartTimes`, because the
    /// prompt-evaluation phase (cold start + prompt tokenisation) sits
    /// between the two and would otherwise drag the rate down for the
    /// first few chunks and then artificially climb as the cold-start
    /// cost is amortised.
    var firstTokenTimes: [UUID: Date] = [:]

    var modes: [RewriteMode]
    var onModeSelected: ((RewriteMode) -> Void)?
    /// Re-run generation for the currently-selected mode. Bypasses the result
    /// cache so the user can roll the dice again on the same prompt.
    var onRegenerate: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Refine the current result with a user-typed instruction. The
    /// callback runs a follow-up LLM stream using the previous output as
    /// input and replaces the result for the current mode in place.
    var onRefine: ((String) -> Void)?

    /// Bumped each time a fresh `.result` lands for the active mode.
    /// Watched by the refine TextField in the popup so it can re-focus
    /// itself after each refinement completes — without re-firing on
    /// unrelated state changes like mode switches.
    @Published var resultArrivalToken: Int = 0

    init(modes: [RewriteMode]) {
        self.modes = modes
    }

    var currentPhase: PopupPhase {
        guard let id = selectedModeId else { return .loading }
        return modePhases[id] ?? .loading
    }
}
