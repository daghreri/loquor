import AppKit
import SwiftUI

/// The floating indicator at the bottom of the screen while dictating, like
/// Wispr Flow's: live waveform while listening, pulsing dots while transcribing.
/// It never takes focus and lets clicks pass through.
@MainActor
final class Pill {
    enum Mode: Equatable {
        case listening(handsFree: Bool)
        case transcribing
        case cleaning   // waiting for Claude
        case message(String)  // a short notice, e.g. the model is still loading
    }

    /// Shows a notice for a few seconds, then hides (unless something newer is showing).
    func flash(_ text: String, seconds: Double = 3) {
        show(.message(text))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.hide()
            }
        }
    }

    private let model = PillModel()
    private var panel: NSPanel?
    private var meter: Timer?
    /// Bumped on every show, so a fade-out that finishes late doesn't hide a newer pill.
    private var generation = 0

    /// Where the waveform reads its loudness from while listening.
    var level: () -> Float = { 0 }
    /// The recording length cap, so the pill can warn before it's reached.
    var limitSeconds = 60.0
    private var listeningSince: Date?

    func show(_ mode: Mode) {
        generation += 1
        if case .listening = mode {
            // Hands-free continues the same recording: keep its clock running.
            if listeningSince == nil { listeningSince = .now }
            model.limit = limitSeconds
            startMeter()
        } else {
            listeningSince = nil
            stopMeter()
        }
        model.mode = mode
        let panel = self.panel ?? makePanel()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { position(panel) }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        stopMeter()
        listeningSince = nil
        guard let panel, panel.isVisible else { return }
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.generation == hiding else { return }
                panel.orderOut(nil)
                self.model.reset()
            }
        }
    }

    private func startMeter() {
        guard meter == nil else { return }
        let meter = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.push(self.level())
                if let since = self.listeningSince {
                    let elapsed = Date.now.timeIntervalSince(since)
                    if Int(elapsed) != Int(self.model.elapsed) { self.model.elapsed = elapsed }
                }
            }
        }
        RunLoop.main.add(meter, forMode: .common)  // keeps running while a menu is open
        self.meter = meter
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom centre of the screen with the mouse (where the user is working), above the Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
    }
}

@MainActor
final class PillModel: ObservableObject {
    static let barCount = 14

    @Published var mode: Pill.Mode = .listening(handsFree: false)
    @Published var elapsed: TimeInterval = 0
    var limit: TimeInterval = 60
    @Published private(set) var levels = [Float](repeating: 0, count: barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        elapsed = 0
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .listening(let handsFree):
                Circle().fill(.red).frame(width: 7, height: 7)
                Waveform(levels: model.levels)
                Clock(elapsed: model.elapsed, limit: model.limit)
                if handsFree {
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            case .transcribing:
                Dots()
            case .cleaning:
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Dots()
            case .message(let text):
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: 3 + CGFloat(levels[i]) * 17)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}

/// "0:42", or in the last 10 seconds an orange countdown so the cut-off is no surprise.
private struct Clock: View {
    let elapsed: TimeInterval
    let limit: TimeInterval

    var body: some View {
        let left = Int((limit - elapsed).rounded(.up))
        let warn = left <= 10
        Text(warn ? "\(max(left, 0))s left" : String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(warn ? Color.orange : Color.white.opacity(0.7))
            .fixedSize()
    }
}

private struct Dots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.8)))
                }
            }
            .frame(width: 60, height: 20)
        }
    }
}
