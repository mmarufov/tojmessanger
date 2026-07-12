# Design System — Toj

## Product

Toj is a private, Tajik-first messenger for iPhone and iPad. It should feel fast,
quiet, premium, and immediately familiar to people who already use modern chat apps.

## Visual Direction

- Black-only interface with matte conversation content and floating Liquid Glass controls.
- Modern Tajik identity is expressed through the restrained crown mark, not flag stripes or ornament.
- Gold behaves like jewelry: rare, precise, and limited to branding or high-intent moments.

## Color

- Canvas: `#000000`
- Base surface: `#08090B`
- Raised surface: `#111318`
- Strong surface: `#191C21`
- Primary text: `#F4F5F7`
- Secondary text: `#9096A1`
- Brand gold: `#D6A936`
- Secure green: `#38C991`
- Destructive actions use the system red semantic color.

## Typography

- Brand and large headings: Onest Semibold/Bold, relative to Dynamic Type styles.
- Messages, labels, controls, and dense lists: native iOS text styles.
- Never use thin text on black or encode meaning through color alone.

## Shape and Spacing

- Base spacing unit: 4 pt; common gaps: 8, 12, 16, 24, 32 pt.
- Search, navigation identity, and composer: full capsules.
- Avatars and compact icon controls: circles.
- Message bubbles: 20 pt radius with a 6 pt conversational tail corner.
- Minimum interactive target: 44×44 pt.

## Motion

- Micro transitions: 140–180 ms; screen/state transitions: 180–220 ms.
- Prefer native navigation, glass morphing, opacity, and short snappy springs.
- Reduce Motion replaces movement and scale with opacity.
- Reduce Transparency replaces glass with an opaque raised surface.

## Liquid Glass

- Use glass only for navigation, search, the composer, and high-level controls.
- Keep lists and bubbles matte for legibility and rendering performance.
- Group nearby glass controls in `GlassEffectContainer` when they morph or interact.

