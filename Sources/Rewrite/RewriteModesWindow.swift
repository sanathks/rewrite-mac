import AppKit
import SwiftUI

struct RewriteModesView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var selectedModeId: UUID?
    @State private var draggingMode: RewriteMode?

    private let maxVisiblePills = 4
    @State private var showingOverflowMenu = false

    private var visibleModes: [RewriteMode] {
        Array(settings.rewriteModes.prefix(maxVisiblePills))
    }

    private var overflowModes: [RewriteMode] {
        guard settings.rewriteModes.count > maxVisiblePills else { return [] }
        return Array(settings.rewriteModes.dropFirst(maxVisiblePills))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Mode selector row
            HStack(spacing: 6) {
                ForEach(visibleModes) { mode in
                    ModePill(
                        name: mode.name.isEmpty ? "Untitled" : mode.name,
                        isSelected: selectedModeId == mode.id,
                        isDefault: settings.defaultModeId == mode.id
                    ) {
                        selectedModeId = mode.id
                    }
                    .onDrag {
                        draggingMode = mode
                        return NSItemProvider(object: mode.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: ModeDropDelegate(
                        targetMode: mode,
                        draggingMode: $draggingMode,
                        modes: $settings.rewriteModes
                    ))
                }

                // Overflow dropdown
                if !overflowModes.isEmpty {
                    Menu {
                        ForEach(overflowModes) { mode in
                            Button {
                                selectedModeId = mode.id
                            } label: {
                                HStack {
                                    Text(mode.name.isEmpty ? "Untitled" : mode.name)
                                    if settings.defaultModeId == mode.id {
                                        Image(systemName: "star.fill")
                                    }
                                    if selectedModeId == mode.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("+\(overflowModes.count)")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            overflowModes.contains(where: { $0.id == selectedModeId })
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Spacer()

                Button {
                    let newMode = RewriteMode(id: UUID(), name: "New Mode", prompt: "")
                    settings.rewriteModes.append(newMode)
                    selectedModeId = newMode.id
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button {
                    guard let id = selectedModeId,
                          settings.rewriteModes.count > 1 else { return }
                    let idx = settings.rewriteModes.firstIndex(where: { $0.id == id })
                    settings.rewriteModes.removeAll { $0.id == id }
                    if let idx, !settings.rewriteModes.isEmpty {
                        let next = min(idx, settings.rewriteModes.count - 1)
                        selectedModeId = settings.rewriteModes[next].id
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(selectedModeId == nil || settings.rewriteModes.count <= 1)
            }

            // Editor for selected mode
            if let binding = selectedModeBinding {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("Mode name", text: binding.name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }

                        Spacer()

                        Button {
                            settings.defaultModeId = selectedModeId
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: settings.defaultModeId == selectedModeId ? "star.fill" : "star")
                                    .font(.system(size: 11))
                                Text(settings.defaultModeId == selectedModeId ? "Default" : "Set as Default")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(settings.defaultModeId == selectedModeId ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.defaultModeId == selectedModeId)
                        .padding(.top, 16)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Prompt")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Use {text} as placeholder for selected text")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        TextEditor(text: binding.prompt)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .frame(maxHeight: .infinity)
                    }
                }
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Text("Select a mode or add a new one")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            if selectedModeId == nil, let first = settings.rewriteModes.first {
                selectedModeId = first.id
            }
        }
    }

    private var selectedModeBinding: Binding<RewriteMode>? {
        guard let id = selectedModeId,
              let idx = settings.rewriteModes.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $settings.rewriteModes[idx]
    }
}

// MARK: - Mode Pill

private struct ModePill: View {
    let name: String
    let isSelected: Bool
    let isDefault: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if isDefault {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drag & Drop

private struct ModeDropDelegate: DropDelegate {
    let targetMode: RewriteMode
    @Binding var draggingMode: RewriteMode?
    @Binding var modes: [RewriteMode]

    func performDrop(info: DropInfo) -> Bool {
        draggingMode = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingMode,
              dragging.id != targetMode.id,
              let fromIndex = modes.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = modes.firstIndex(where: { $0.id == targetMode.id }) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            modes.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
