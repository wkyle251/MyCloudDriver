import AppKit
import SwiftUI

/// Keep a single native editor for each field at every window width. Swapping
/// ViewThatFits candidates recreates editors and can leave focus on a field
/// that is no longer visible, especially when a long URL changes ideal size.
struct SharedLinkInputBar: View {
    @Binding var url: String
    @Binding var passcode: String
    let canSubmit: Bool
    let onSubmit: () -> Void

    private enum Field: Hashable { case url, passcode }
    @FocusState private var focusedField: Field?

    var body: some View {
        SharedLinkInputLayout {
            fieldContainer(.url, icon: "link") {
                TextField("https://mypikpak.com/s/…", text: $url)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .url)
                    .accessibilityLabel("PikPak shared-link URL")
                    .accessibilityIdentifier("shared-link-url")
                    .onSubmit(submit)
            }
            fieldContainer(.passcode, icon: "key") {
                SecureField("Access code (optional)", text: $passcode)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .passcode)
                    .accessibilityLabel("Shared-link access code (optional)")
                    .accessibilityIdentifier("shared-link-passcode")
                    .onSubmit(submit)
            }
            Button {
                if let value = NSPasteboard.general.string(forType: .string), !value.isEmpty {
                    url = value
                }
                focusedField = .url
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard").lineLimit(1)
            }
            Button(action: submit) {
                Label("Add Link", systemImage: "plus.circle.fill").lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .help("Add this URL. Other shared links can continue loading at the same time.")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }

    private func fieldContainer<Content: View>(
        _ field: Field, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            content()
                // Fill the actual allocated bounds, even with empty text.
                // The native text editor must not extend beyond the visible
                // background or shrink its click target to the placeholder.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded {
            // Icon/padding clicks also focus the field. Do not reset an
            // already focused editor's native selection or caret position.
            if focusedField != field { focusedField = field }
        })
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    focusedField == field ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08),
                    lineWidth: focusedField == field ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

/// Pure geometry is shared with regression tests. Breakpoints depend on the
/// viewport and buttons, never URL/passcode contents or native editor ideals.
enum SharedLinkInputGeometry {
    static let spacing: CGFloat = 9
    static let minimumURLWidth: CGFloat = 260
    static let minimumPasscodeWidth: CGFloat = 175

    static func frames(width: CGFloat, paste: CGSize, add: CGSize) -> [CGRect] {
        let width = width.isFinite ? max(width, 0) : 800
        let height = max(30, paste.height, add.height)
        let buttonsWidth = paste.width + spacing + add.width
        let inlineMinimum = minimumURLWidth + minimumPasscodeWidth + buttonsWidth + 2 * spacing

        func row(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: max(width, 0), height: height)
        }
        if width >= inlineMinimum {
            let fieldsWidth = width - buttonsWidth - 2 * spacing
            let urlWidth = max(minimumURLWidth, fieldsWidth * 0.58)
            let passcodeWidth = fieldsWidth - urlWidth
            let buttonsX = width - buttonsWidth
            return [
                row(0, 0, urlWidth), row(urlWidth + spacing, 0, passcodeWidth),
                row(buttonsX, 0, paste.width), row(width - add.width, 0, add.width),
            ]
        }
        let secondRow = height + spacing
        if width >= minimumPasscodeWidth + spacing + buttonsWidth {
            return [
                row(0, 0, width), row(0, secondRow, width - buttonsWidth - spacing),
                row(width - buttonsWidth, secondRow, paste.width), row(width - add.width, secondRow, add.width),
            ]
        }
        let thirdRow = secondRow * 2
        if width >= buttonsWidth {
            return [
                row(0, 0, width), row(0, secondRow, width),
                row(width - buttonsWidth, thirdRow, paste.width), row(width - add.width, thirdRow, add.width),
            ]
        }
        return [
            row(0, 0, width), row(0, secondRow, width),
            row(0, thirdRow, width), row(0, secondRow * 3, width),
        ]
    }
}

private struct SharedLinkInputLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 800
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: max(width, 0), height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        return SharedLinkInputGeometry.frames(
            width: width,
            paste: subviews[2].sizeThatFits(.unspecified),
            add: subviews[3].sizeThatFits(.unspecified)
        )
    }
}
