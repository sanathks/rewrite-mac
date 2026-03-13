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

            case .result(let text):
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

                HStack(spacing: 0) {
                    ActionButton(label: "Replace") { state.onReplace?(text) }
                    ActionButton(label: "Copy") { state.onCopy?(text) }

                    Spacer()

                    Button {
                        state.onCopy?(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }

            case .error(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.9))

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.vertical, 8)

                HStack(spacing: 0) {
                    ActionButton(label: "Dismiss") { state.onCancel?() }
                    Spacer()
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

struct ActionButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
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
