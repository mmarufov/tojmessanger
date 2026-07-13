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

    /// Signature interactive accent. Toj uses gold the way Telegram uses blue: send button,
    /// primary CTAs, active unread badges, selected pills — precise, high-intent moments.
    static let accent = gold
    /// Foreground on top of `accent` fills (black on gold).
    static let onAccent = canvas
    static let danger = Color.red
    static let hairline = Color.white.opacity(0.06)
    static let hairlineStrong = Color.white.opacity(0.12)
    static let tertiaryText = Color(hex: 0x6A6F79)
    /// Outgoing ("mine") message bubble fill — premium warm graphite, signed by a faint gold hairline.
    static let bubbleMine = Color(hex: 0x1B1D21)

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

/// Spacing scale (base unit 4pt). Prefer these over raw literals on touched views.
enum TojSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner-radius scale. Capsules/circles use `Capsule()`/`Circle()` directly.
enum TojRadius {
    static let field: CGFloat = 18
    static let tile: CGFloat = 14
    static let card: CGFloat = 20
    static let cardLarge: CGFloat = 22
    static let bubble: CGFloat = 20
    static let bubbleTail: CGFloat = 6
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

// MARK: - Interaction

/// Reactive press feedback: gentle scale + dim on press. Scale is dropped under Reduce Motion.
struct TojPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : scale)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TojPressableStyle {
    static var tojPressable: TojPressableStyle { TojPressableStyle() }
    static func tojPressable(scale: CGFloat) -> TojPressableStyle { TojPressableStyle(scale: scale) }
}

// MARK: - Shared components

/// A circular Liquid Glass icon button — the floating control used across headers and toolbars.
struct TojGlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 46
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// A floating large-title header with an optional secondary line and trailing glass controls.
/// Used at the top of scroll content so every primary screen shares one chrome grammar.
struct TojNavHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var subtitleIcon: String? = nil
    var subtitleColor: Color = TojTheme.secondaryText
    @ViewBuilder var trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleIcon: String? = nil,
        subtitleColor: Color = TojTheme.secondaryText,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIcon = subtitleIcon
        self.subtitleColor = subtitleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TojTheme.heading(.largeTitle, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                if let subtitle {
                    Label {
                        Text(subtitle)
                    } icon: {
                        if let subtitleIcon { Image(systemName: subtitleIcon) }
                    }
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                }
            }
            Spacer(minLength: TojSpacing.md)
            HStack(spacing: TojSpacing.sm) { trailing }
        }
        .padding(.top, TojSpacing.md)
        .padding(.bottom, 15)
    }
}

extension TojNavHeader where Trailing == EmptyView {
    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleIcon: String? = nil,
        subtitleColor: Color = TojTheme.secondaryText
    ) {
        self.init(title, subtitle: subtitle, subtitleIcon: subtitleIcon, subtitleColor: subtitleColor) { EmptyView() }
    }
}

/// A rounded-square icon tile for grouped rows. Premium/monochrome by default; pass a semantic
/// `tint` (green privacy, gold premium, red destructive) to color a specific row sparingly.
struct TojIconTile: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 30

    private var glyphColor: Color { tint ?? TojTheme.text }
    private var fillColor: Color { tint.map { $0.opacity(0.18) } ?? TojTheme.strong }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: (size * 0.46).rounded(), weight: .semibold))
            .foregroundStyle(glyphColor)
            .frame(width: size, height: size)
            .background(fillColor, in: RoundedRectangle(cornerRadius: TojRadius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TojRadius.tile, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
    }
}

/// An inset grouped card with an optional uppercase section title. One grammar for
/// settings, profile, and gallery sections.
struct TojSectionCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TojSpacing.sm) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.secondaryText)
                    .textCase(.uppercase)
                    .padding(.leading, 5)
            }
            VStack(spacing: 0) { content }
                .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
        }
    }
}

/// A horizontally-scrollable segmented pill control (Telegram-style "All / …" filters and
/// search scopes). Selected pill fills with the gold accent.
struct TojPillFilter<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: TojSpacing.sm) {
                ForEach(items, id: \.self) { item in
                    let selected = item == selection
                    Button {
                        selection = item
                        TojFeedback.selection()
                    } label: {
                        Text(title(item))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? TojTheme.onAccent : TojTheme.secondaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(selected ? TojTheme.accent : TojTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.tojPressable)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 0)
        .animation(TojTheme.microAnimation, value: selection)
    }
}
