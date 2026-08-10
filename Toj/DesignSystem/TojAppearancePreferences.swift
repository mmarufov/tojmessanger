import Observation
import SwiftUI

enum TojAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case tajik = "tg"
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System Language")
        case .tajik: "Тоҷикӣ"
        case .russian: "Русский"
        case .english: "English"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }
}

enum TojAccentPreset: String, CaseIterable, Identifiable, Sendable {
    case gold
    case blue
    case green
    case violet

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .gold: "Gold"
        case .blue: "Blue"
        case .green: "Green"
        case .violet: "Violet"
        }
    }

    var color: Color {
        switch self {
        case .gold: Color(hex: 0xD6A936)
        case .blue: Color(hex: 0x4AA8FF)
        case .green: Color(hex: 0x38C991)
        case .violet: Color(hex: 0xA779FF)
        }
    }
}

enum TojChatWallpaperPreset: String, CaseIterable, Identifiable, Sendable {
    case pureBlack
    case midnight
    case graphite
    case dusk

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .pureBlack: "Pure Black"
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .dusk: "Dusk"
        }
    }
}

enum TojChatTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .small
        case .standard: .large
        case .large: .xxLarge
        case .extraLarge: .accessibility1
        }
    }
}

@MainActor
@Observable
final class TojAppearancePreferences {
    static let shared = TojAppearancePreferences()

    private enum Key {
        static let language = "toj.appearance.language"
        static let accent = "toj.appearance.accent"
        static let wallpaper = "toj.appearance.wallpaper"
        static let textSize = "toj.appearance.text-size"
    }

    private let defaults: UserDefaults

    var language: TojAppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    var accent: TojAccentPreset { didSet { defaults.set(accent.rawValue, forKey: Key.accent) } }
    var wallpaper: TojChatWallpaperPreset { didSet { defaults.set(wallpaper.rawValue, forKey: Key.wallpaper) } }
    var textSize: TojChatTextSize { didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = TojAppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        accent = TojAccentPreset(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .gold
        wallpaper = TojChatWallpaperPreset(rawValue: defaults.string(forKey: Key.wallpaper) ?? "") ?? .pureBlack
        textSize = TojChatTextSize(rawValue: defaults.string(forKey: Key.textSize) ?? "") ?? .standard
    }
}

struct TojChatWallpaper: View {
    @Environment(TojAppearancePreferences.self) private var preferences

    var body: some View {
        ZStack {
            switch preferences.wallpaper {
            case .pureBlack:
                Color.black
            case .midnight:
                LinearGradient(
                    colors: [Color(hex: 0x07101C), Color(hex: 0x020407), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .graphite:
                LinearGradient(
                    colors: [Color(hex: 0x171A20), Color(hex: 0x08090B)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                wallpaperPattern.opacity(0.20)
            case .dusk:
                LinearGradient(
                    colors: [Color(hex: 0x1A1024), Color(hex: 0x120D0A), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var wallpaperPattern: some View {
        Canvas { context, size in
            let spacing: CGFloat = 42
            for x in stride(from: -spacing, through: size.width + spacing, by: spacing) {
                for y in stride(from: -spacing, through: size.height + spacing, by: spacing) {
                    let rect = CGRect(x: x, y: y, width: 16, height: 16)
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 5),
                        with: .color(.white.opacity(0.12)),
                        lineWidth: 0.6
                    )
                }
            }
        }
    }
}
