# Changelog

All notable changes to Toj are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to a `MAJOR.MINOR.PATCH.BUILD` version scheme.

## [0.1.0.0] — 2026-07-12

First versioned release. Establishes the visual identity, design system, and
messaging presentation layer on top of the milestone M1–M4 cloud skeleton.

### Added
- **Design system** (`Toj/DesignSystem/TojTheme.swift`, `DESIGN.md`): black-only
  interface with matte conversation content, floating Liquid Glass controls, a
  restrained crown mark, and a documented color, typography, spacing, and motion
  language.
- **Onest typeface** bundled for brand and large headings
  (`Toj/Resources/Fonts/`), with native iOS text styles for dense content.
- **App icons** for light, dark, and tinted appearances.
- **Messaging presentation layer** (`Toj/Features/Cloud/MessagingPresentation.swift`)
  with unit coverage (`TojTests/MessagingPresentationTests.swift`).
- **Conversation experience** and rich demo surfaces
  (`Toj/Features/Cloud/ConversationExperience.swift`, `RichDemoSurfaces.swift`).
- **Localization** via `Toj/Localizable.xcstrings` for a Tajik-first UI.

### Changed
- Overhauled the cloud chat UI and view model (`CloudRootView.swift`,
  `CloudAppModel.swift`) to adopt the new design system.
- Refined local store handling and its tests (`CloudLocalStore.swift`,
  `CloudLocalStoreTests.swift`).
- Updated project configuration, Info.plist, and prep tooling to bundle fonts,
  icons, and localized resources.

[0.1.0.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.1.0.0
