import Foundation

/// Drives waveform animation based on speech callback signals.
final class AudioLevelMonitor {
    private var timer: DispatchSourceTimer?
    private var targetLevel: Float = 0
    private var currentLevel: Float = 0
    var onLevel: ((Float) -> Void)?

    func start() {
        targetLevel = 0.25
        currentLevel = 0.2

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(33))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    private func tick() {
        let diff = targetLevel - currentLevel
        currentLevel += diff * 0.25
        let jitter = Float.random(in: -0.08...0.08)
        let level = max(0, min(1, currentLevel + jitter))
        targetLevel *= 0.96
        // Keep a healthy idle pulse while recording
        if targetLevel < 0.35 {
            targetLevel = Float.random(in: 0.3...0.45)
        }
        onLevel?(level)
    }

    func speechActive() {
        targetLevel = Float.random(in: 0.7...1.0)
    }

    func idlePulse() {
        targetLevel = 0.35
    }

    func stop() {
        timer?.cancel()
        timer = nil
        currentLevel = 0
        targetLevel = 0
    }

    deinit {
        stop()
    }
}
