import SwiftUI

private let popupWidth: CGFloat = 340
private let maxContentHeight: CGFloat = 300

struct PopupView: View {
    @ObservedObject var state: PopupState
    @State private var hoveredMode: RewriteMode.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode pills - always visible
            FlowLayout(spacing: 6) {
                ForEach(state.modes) { mode in
                    ModeButton(
                        label: mode.name,
                        isSelected: state.selectedModeId == mode.id,
                        isHovered: hoveredMode == mode.id,
                        hasResult: state.modePhases[mode.id] != nil
                    ) {
                        state.onModeSelected?(mode)
                    }
                    .onHover { hovering in
                        hoveredMode = hovering ? mode.id : nil
                    }
                }
            }
            .padding(.bottom, 10)

            // Content area
            switch state.currentPhase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Processing...")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }

            case .streaming(let text, let metadata):
                resultBody(text: text, metadata: metadata, streaming: true)

            case .result(let text, let metadata):
                resultBody(text: text, metadata: metadata, streaming: false)

            case .error(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.9))

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.vertical, 8)

                HStack(spacing: 6) {
                    PrimaryActionButton(label: "Retry", shortcut: "⌘R") {
                        state.onRegenerate?()
                    }
                    Spacer()
                    IconActionButton(icon: "xmark", help: "Dismiss (Esc)") {
                        state.onCancel?()
                    }
                }
            }
        }
        .padding(10)
        .frame(width: popupWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func resultBody(text: String, metadata: ResultMetadata?, streaming: Bool) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.9))
            .textSelection(.enabled)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: maxContentHeight, alignment: .leading)

        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 8)

        HStack(spacing: 6) {
            PrimaryActionButton(
                label: "Replace",
                shortcut: "↩",
                disabled: streaming
            ) {
                state.onReplace?(text)
            }

            Spacer()

            IconActionButton(
                icon: "arrow.clockwise",
                help: "Regenerate (⌘R)",
                disabled: streaming
            ) {
                state.onRegenerate?()
            }
            IconActionButton(
                icon: "doc.on.doc",
                help: "Copy (⌘C)",
                disabled: streaming
            ) {
                state.onCopy?(text)
            }
            IconActionButton(icon: "xmark", help: "Dismiss (Esc)") {
                state.onCancel?()
            }
        }

        if let metadata {
            Text(metadataLine(metadata))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 6)
        }
    }

    private func metadataLine(_ m: ResultMetadata) -> String {
        // Footer is always "<model> · <N> tok/s" — same shape during stream
        // and after, so the eye doesn't have to re-parse on completion.
        let tps = m.tokensPerSecond
        let tpsStr = tps >= 10 ? String(Int(tps.rounded())) : String(format: "%.1f", tps)
        return "\(m.modelName) · \(tpsStr) tok/s"
    }
}

struct ModeButton: View {
    let label: String
    let isSelected: Bool
    let isHovered: Bool
    var hasResult: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if hasResult && !isSelected {
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 4, height: 4)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : (isHovered ? .white : .white.opacity(0.7)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : (isHovered ? Color.white.opacity(0.14) : Color.white.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.35 : (isHovered ? 0.2 : 0.12)), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if i < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

/// Filled primary action — visually dominant. Used for the single "best"
/// action (Replace / Retry).
struct PrimaryActionButton: View {
    let label: String
    let shortcut: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(disabled ? 0.3 : 0.7))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(disabled ? 0.4 : 1))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        disabled
                            ? Color.white.opacity(0.08)
                            : (isHovered ? Color.white.opacity(0.30) : Color.white.opacity(0.22))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(disabled ? 0.15 : 0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

/// Icon-only secondary action. Used for Regenerate / Copy / Dismiss.
struct IconActionButton: View {
    let icon: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(
                    disabled
                        ? .white.opacity(0.2)
                        : (isHovered ? .white : .white.opacity(0.55))
                )
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(!disabled && isHovered ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

