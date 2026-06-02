import SwiftUI

struct EventIconButton: View {

    let systemImage: String
    let hintText: String
    let tint: Color
    let action: () -> Void

    @State private var isPressing = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.6), lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    if isPressing {
                        Text(hintText)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .shadow(radius: 2)
                            .offset(y: -42)
                            .fixedSize()
                            .zIndex(1)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(hintText)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressing {
                        isPressing = true
                    }
                }
                .onEnded { _ in
                    isPressing = false
                }
        )
    }
}
