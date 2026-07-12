import SwiftUI
import UIKit

enum TojTheme {
    static let canvas = Color(hex: 0x000000)
    static let base = Color(hex: 0x08090B)
    static let raised = Color(hex: 0x111318)
    static let strong = Color(hex: 0x191C21)
    static let text = Color(hex: 0xF4F5F7)
    static let secondaryText = Color(hex: 0x9096A1)
    static let gold = Color(hex: 0xD6A936)
    static let secure = Color(hex: 0x38C991)

    static let microAnimation = Animation.snappy(duration: 0.16, extraBounce: 0.04)
    static let stateAnimation = Animation.snappy(duration: 0.21, extraBounce: 0.06)

    static func heading(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .custom("Onest", size: preferredSize(for: style), relativeTo: style).weight(weight)
    }

    private static func preferredSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        default: 17
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

struct TojGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(contrast == .increased ? Color(hex: 0x24272D) : TojTheme.strong, in: shape)
                .overlay(shape.stroke(Color.white.opacity(contrast == .increased ? 0.28 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

extension View {
    func tojGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(TojGlassModifier(shape: shape, interactive: interactive))
    }
}

struct TojMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(TojTheme.raised)
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .stroke(TojTheme.gold.opacity(0.28), lineWidth: 1)
            CrownShape()
                .stroke(TojTheme.gold, style: StrokeStyle(lineWidth: max(1.5, size * 0.026), lineCap: .round, lineJoin: .round))
                .padding(size * 0.24)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.maxY * 0.58))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.maxY * 0.58))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.maxY * 0.84))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY * 0.84))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY))
        return path
    }
}

struct TojAvatar: View {
    let title: String
    var size: CGFloat = 52
    var highlighted = false

    private var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "T"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    highlighted
                        ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4B401F), Color(hex: 0x211D13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x292D34), TojTheme.raised], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            Text(initial)
                .font(TojTheme.heading(.headline, weight: .semibold))
                .foregroundStyle(highlighted ? TojTheme.gold : TojTheme.text)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(title)
    }
}

enum TojFeedback {
    @MainActor static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor static func sent() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
