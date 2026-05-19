import AppKit
import SwiftUI

final class RecordingIndicatorPanel {
    private var panel: FloatingPanel?
    private var hostingController: NSHostingController<RecordingIndicatorView>?
    private let state = RecordingIndicatorState()
    private var isBuilt = false
    private var escapeMonitor: Any?

    /// Pre-build the panel off-screen so show() is instant.
    func prebuild() {
        guard !isBuilt else { return }
        buildPanel()
        isBuilt = true
    }

    func show() {
        state.phase = .recording
        state.partialText = ""
        state.audioLevel = 0.2
        state.warning = nil
        state.streamingEnabled = false
        state.isHandsFree = false
        state.toastMessage = nil
        state.onFinish = nil

        if !isBuilt {
            buildPanel()
            isBuilt = true
        }

        // Resize panel based on streaming mode
        let width = state.streamingEnabled ? Self.streamingWidth : Self.compactWidth
        if let panel {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                let origin = NSPoint(
                    x: screen.frame.midX - width / 2,
                    y: screen.visibleFrame.minY + 20
                )
                panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: Self.panelHeight)), display: true)
            }
        }

        panel?.orderFront(nil)
    }

    func showHandsFree(onFinish: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.state.isHandsFree = true
            self.state.onFinish = onFinish
            self.state.toastMessage = "Hands-free mode"

            // Resize panel wider and taller for hands-free UI with toast
            guard let panel = self.panel else { return }
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                let origin = NSPoint(
                    x: screen.frame.midX - Self.handsFreeWidth / 2,
                    y: screen.visibleFrame.minY + 20
                )
                panel.setFrame(
                    NSRect(origin: origin, size: NSSize(width: Self.handsFreeWidth, height: Self.handsFreeHeight)),
                    display: true
                )
            }

            // Auto-dismiss toast after 5 seconds, then shrink panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.state.toastMessage = nil
                }
                // Shrink panel back to normal height after toast disappears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let panel = self.panel, self.state.isHandsFree else { return }
                    let screen = NSScreen.main ?? NSScreen.screens.first
                    if let screen {
                        let origin = NSPoint(
                            x: screen.frame.midX - Self.handsFreeWidth / 2,
                            y: screen.visibleFrame.minY + 20
                        )
                        panel.setFrame(
                            NSRect(origin: origin, size: NSSize(width: Self.handsFreeWidth, height: Self.panelHeight)),
                            display: true
                        )
                    }
                }
            }
        }
    }

    private static let streamingWidth: CGFloat = 360
    private static let compactWidth: CGFloat = 116
    private static let handsFreeWidth: CGFloat = 168
    private static let handsFreeHeight: CGFloat = 100
    private static let processingWidth: CGFloat = 180
    private static let panelHeight: CGFloat = 68

    private func buildPanel() {
        let view = RecordingIndicatorView(state: state)
        let hosting = NSHostingController(rootView: view)
        hostingController = hosting

        let panelSize = NSSize(width: Self.compactWidth, height: Self.panelHeight)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let origin: NSPoint
        if let screen {
            origin = NSPoint(
                x: screen.frame.midX - panelSize.width / 2,
                y: screen.visibleFrame.minY + 20
            )
        } else {
            origin = .zero
        }

        let floatingPanel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: panelSize)
        )
        floatingPanel.contentView = hosting.view
        panel = floatingPanel
    }

    func updatePartialText(_ text: String) {
        DispatchQueue.main.async {
            self.state.partialText = text
            self.state.warning = nil
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            // Smooth the level: rise quickly, fall slowly
            let target = CGFloat(level)
            let current = self.state.audioLevel
            if target > current {
                self.state.audioLevel = current + (target - current) * 0.4
            } else {
                self.state.audioLevel = current + (target - current) * 0.15
            }
        }
    }

    func showWarning(_ message: String) {
        DispatchQueue.main.async {
            self.state.warning = message
        }
    }

    /// Show the processing phase with a custom label (e.g. "Transcribing…",
    /// "Cleaning…"). The waveform keeps drawing but in idle mode — slower
    /// and lower amplitude — alongside an animated icon + shimmering text.
    func showStage(_ label: String) {
        DispatchQueue.main.async {
            self.state.phase = .processing
            self.state.stageLabel = label
            self.state.audioLevel = 0
            self.state.warning = nil
            self.resizePanelToProcessing()
        }
    }

    private func resizePanelToProcessing() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - Self.processingWidth / 2,
            y: visibleFrame.minY + 20
        )
        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: Self.processingWidth, height: Self.panelHeight)),
            display: true,
            animate: false
        )
    }

    /// Show the transcribed text for preview before inserting.
    /// Calls onInsert after countdown, or onCancel if Escape is pressed.
    func showPreview(
        text: String,
        duration: TimeInterval = 2.0,
        onInsert: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            self.state.phase = .preview
            self.state.previewText = text
            self.state.previewCountdown = duration
            self.state.audioLevel = 0
            self.state.warning = nil
            self.resizePanelToFull()
        }

        // Countdown timer
        let startTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, duration - elapsed)
            self.state.previewCountdown = remaining
            if remaining <= 0 {
                t.invalidate()
                self.removeEscapeMonitor()
                onInsert()
            }
        }

        // Listen for Escape to cancel
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                timer.invalidate()
                self?.removeEscapeMonitor()
                onCancel()
                return nil
            }
            return event
        }
    }

    func close() {
        removeEscapeMonitor()
        panel?.orderOut(nil)
    }

    private func resizePanelToCompact() {
        guard let panel else { return }
        let width: CGFloat = 80
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.minY + 20
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: Self.panelHeight)), display: true)
        }
    }

    private func resizePanelToFull() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.midX - Self.streamingWidth / 2,
                y: visibleFrame.minY + 20
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.streamingWidth, height: Self.panelHeight)), display: true)
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

// MARK: - State

enum RecordingPhase {
    case recording
    case processing
    case preview
}

final class RecordingIndicatorState: ObservableObject {
    @Published var phase: RecordingPhase = .recording
    @Published var partialText: String = ""
    @Published var audioLevel: CGFloat = 0
    @Published var warning: String?
    @Published var previewText: String = ""
    @Published var previewCountdown: TimeInterval = 0
    @Published var streamingEnabled: Bool = true
    @Published var isHandsFree: Bool = false
    @Published var toastMessage: String?
    /// Label shown in the .processing phase (e.g. "Transcribing…", "Cleaning…").
    @Published var stageLabel: String?
    var onFinish: (() -> Void)?
}

// MARK: - Waveform

private struct WaveLayer {
    let speed: Double
    let freq: Double
    let phase: Double
    let amp: CGFloat
    /// Base color of this band. Stroked twice: a wide low-alpha pass for the
    /// "glow" halo, then a thin core line at full alpha.
    let color: Color
}

/// Three colored bands interleaving — cyan / magenta / amber. Each band is a
/// sin curve at a different speed/phase; the offsets keep them weaving rather
/// than overlapping flatly.
private let waveLayers: [WaveLayer] = [
    WaveLayer(speed: 2.8, freq: 2.5, phase: 0.0, amp: 0.9,
              color: Color(red: 0.30, green: 0.75, blue: 1.00)),   // electric cyan
    WaveLayer(speed: 3.5, freq: 3.0, phase: 1.2, amp: 0.7,
              color: Color(red: 1.00, green: 0.35, blue: 0.80)),   // magenta/pink
    WaveLayer(speed: 4.5, freq: 3.8, phase: 2.5, amp: 1.0,
              color: Color(red: 1.00, green: 0.65, blue: 0.20)),   // warm amber
]

/// Build one "fiber" of a band: a single sinusoidal curve at the given time,
/// offset by `fiber` ∈ [-1, 1] so that stacking many fibers produces the
/// wireframe-ribbon look from the reference image. Fibers near the centre
/// trace the main wave; fibers at the edges sit slightly above/below and
/// fan out at the high-amplitude regions to give the band visible thickness.
private func buildWaveFiberPath(
    wave: WaveLayer,
    fiber: Double,
    time: Double,
    level: CGFloat,
    maxAmp: CGFloat,
    midY: CGFloat,
    steps: Int
) -> Path {
    var path = Path()
    // Per-fiber phase nudge so adjacent fibers shimmer past each other.
    let fiberPhase = fiber * 0.55
    // Band thickness — how far above/below midline the outer fibers sit.
    let bandThickness: CGFloat = maxAmp * 0.22

    for x in 0...steps {
        let t: Double = Double(x) / Double(steps)
        // Bell-curve envelope so the band fans out in the middle of the
        // panel and tapers to nothing at the edges.
        let envelope: Double = sin(t * .pi)

        let y1: Double = sin(time * wave.speed + t * wave.freq * .pi * 2 + wave.phase + fiberPhase)
        let speedA: Double = wave.speed * 1.6
        let freqA: Double = wave.freq * 1.4
        let y2: Double = sin(time * speedA + t * freqA * .pi * 2 + wave.phase + 0.8) * 0.4
        let speedB: Double = wave.speed * 0.7
        let freqB: Double = wave.freq * 0.6
        let y3: Double = sin(time * speedB + t * freqB * .pi * 2 + wave.phase + 2.0) * 0.3

        let combined: Double = (y1 + y2 + y3) / 1.7
        let amplitude: CGFloat = maxAmp / 2 * level * wave.amp * CGFloat(envelope)
        // Fiber's own vertical offset, scaled by envelope so the ribbon is
        // thick in the middle and thin at the edges (3D-ish).
        let fiberOffset: CGFloat = CGFloat(fiber) * bandThickness * CGFloat(envelope)
        let py: CGFloat = midY + CGFloat(combined) * amplitude + fiberOffset

        if x == 0 {
            path.move(to: CGPoint(x: CGFloat(x), y: py))
        } else {
            path.addLine(to: CGPoint(x: CGFloat(x), y: py))
        }
    }
    return path
}

struct WaveformView: View {
    let audioLevel: CGFloat
    var waveWidth: CGFloat = 40
    /// When true, the waveform animates at half speed with a constant low
    /// amplitude — used for the .processing phase so it visibly idles rather
    /// than reacting to a (silent) mic.
    var isIdle: Bool = false
    private let waveHeight: CGFloat = 32

    /// Number of parallel "fibers" per band. More fibers → denser ribbon →
    /// the wireframe look in the reference image. Scaled down at small
    /// panel widths to keep things visually balanced.
    private var fibersPerBand: Int {
        waveWidth >= 60 ? 18 : 10
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let timeScale: Double = isIdle ? 0.45 : 1.0
            let time = timeline.date.timeIntervalSinceReferenceDate * timeScale
            // Force a steady "breathing" level during idle so the band visibly
            // pulses without ever going flat.
            let level: CGFloat = isIdle
                ? 0.32 + 0.10 * CGFloat(sin(time * 1.6))
                : min(1.0, audioLevel * 1.3)

            Canvas { context, size in
                let midY = size.height / 2
                let steps = Int(size.width)
                let fiberCount = fibersPerBand

                // Fiber alpha — many overlapping thin lines sum visually, so
                // each line is faint individually. Boost slightly with audio
                // level so the bands "light up" when you speak.
                let alpha: Double = 0.32 + 0.25 * Double(level)
                let lineWidth: CGFloat = waveWidth >= 60 ? 0.6 : 0.8

                for wave in waveLayers {
                    for i in 0..<fiberCount {
                        // Map fiber index to [-1, 1] so the band stacks above
                        // and below the centerline symmetrically.
                        let fiber: Double = (Double(i) / Double(fiberCount - 1) - 0.5) * 2

                        // Scale maxAmp below frame height so the peak fiber
                        // excursion (wave amplitude + outer fiber offset)
                        // always fits inside the canvas without clipping.
                        let path = buildWaveFiberPath(
                            wave: wave,
                            fiber: fiber,
                            time: time,
                            level: level,
                            maxAmp: waveHeight * 0.60,
                            midY: midY,
                            steps: steps
                        )

                        // Fade fibers slightly at the edges of the band so
                        // the ribbon has a soft border rather than a sharp
                        // cut-off.
                        let edgeFade: Double = 1.0 - 0.35 * Swift.abs(fiber)
                        context.stroke(
                            path,
                            with: .color(wave.color.opacity(alpha * edgeFade)),
                            lineWidth: lineWidth
                        )
                    }
                }
            }
            .frame(width: waveWidth, height: waveHeight)
        }
    }
}

// MARK: - Stage label

/// Animated label shown during the .processing phase: an SF Symbol with a
/// native symbolEffect + the label text with a moving "shimmer" highlight
/// sweeping left → right. The whole view cross-fades when the label changes.
struct StageLabel: View {
    let label: String

    /// Pick an SF Symbol that matches the stage. Falls back to a neutral
    /// "thinking" indicator for unknown labels.
    private var iconName: String {
        let lower = label.lowercased()
        if lower.contains("transcrib") { return "waveform" }
        if lower.contains("clean") || lower.contains("polish") || lower.contains("refin") {
            return "sparkles"
        }
        return "ellipsis"
    }

    var body: some View {
        HStack(spacing: 6) {
            stageIcon
            shimmerText
        }
        .id(label) // forces cross-fade when label string changes
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private var stageIcon: some View {
        let icon = Image(systemName: iconName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.30, green: 0.75, blue: 1.00),
                        Color(red: 1.00, green: 0.35, blue: 0.80)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

        if iconName == "sparkles" {
            icon.symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        } else {
            icon.symbolEffect(.pulse, options: .repeating)
        }
    }

    /// Text foreground style is an animated gradient that "sweeps" a brighter
    /// stop across the text every ~1.6 s. Renders the shimmer-loading look
    /// you see in Copilot / Linear / Notion AI.
    private var shimmerText: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let cycle: Double = 1.6
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            // Centre of the bright stop, swept slightly past both edges so
            // the highlight enters from one side and leaves on the other.
            let center = phase * 1.4 - 0.2
            let lo = max(0, center - 0.18)
            let hi = min(1, center + 0.18)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.55), location: 0),
                            .init(color: .white.opacity(0.55), location: lo),
                            .init(color: .white, location: center),
                            .init(color: .white.opacity(0.55), location: hi),
                            .init(color: .white.opacity(0.55), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - View

struct RecordingIndicatorView: View {
    @ObservedObject var state: RecordingIndicatorState

    private var isCompact: Bool {
        switch state.phase {
        case .recording:
            return !state.streamingEnabled
        case .processing:
            return false
        case .preview:
            return false
        }
    }

    private var viewWidth: CGFloat {
        if state.phase == .recording && state.isHandsFree {
            return 120
        }
        if state.phase == .processing {
            return 160
        }
        return isCompact ? 56 : 340
    }

    var body: some View {
        VStack(spacing: 6) {
            if let toast = state.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.75))
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                switch state.phase {
                case .recording:
                    if state.isHandsFree {
                        WaveformView(audioLevel: state.audioLevel, waveWidth: 80)

                        Button {
                            state.onFinish?()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else if state.streamingEnabled {
                        WaveformView(audioLevel: state.audioLevel, waveWidth: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            if let warning = state.warning {
                                Text(warning)
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange.opacity(0.9))
                            } else if state.partialText.isEmpty {
                                Text("Listening...")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Text(state.partialText)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(6)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        WaveformView(audioLevel: state.audioLevel, waveWidth: 80)
                    }

                case .processing:
                    HStack(spacing: 8) {
                        WaveformView(audioLevel: 0, waveWidth: 30, isIdle: true)
                        StageLabel(label: state.stageLabel ?? "Processing…")
                            .animation(.easeInOut(duration: 0.22), value: state.stageLabel)
                    }

                case .preview:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.previewText)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(3)

                        HStack(spacing: 4) {
                            ProgressView(
                                value: max(0, 2.0 - state.previewCountdown),
                                total: 2.0
                            )
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                            .tint(.accentColor)

                            Text("Esc to cancel")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }
            .padding(.horizontal, isCompact ? 16 : 12)
            .padding(.vertical, 8)
            .frame(width: viewWidth, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.75))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .animation(.easeInOut(duration: 0.3), value: state.toastMessage == nil)
        .preferredColorScheme(.dark)
    }
}
