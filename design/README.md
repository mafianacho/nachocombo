# Nacho Pet design (web first, then native)

The pet's screens are designed and checked in a browser first, because the app cannot be run on a Mac here. The app is
then ported from the same tokens and the same structure.

- `tokens.json` — the single source: sizes, spacing, radii, colours (light/dark), font, shadows, motion durations.
  `node scripts/gen-design-tokens.mjs` writes `web/tokens.css` (CSS variables) and
  `Sources/NachoComboCore/Pet/PetDesignTokens.swift` (Swift constants). `--check` fails when either is out of date;
  `PetDesignTokenTests` (part of `swift test`) checks that all three carry the same values and that text colours reach
  WCAG 4.5:1 on the surfaces they sit on.
- `web/` — static mockup, no dependencies or network: `index.html` lists the scenes; `?scene=<id>&theme=dark`,
  `&pair=1` (light and dark side by side), `&still=0` (with animation). The character art is loaded from
  `Resources/Nacho` (© Mafianacho, all rights reserved; not open source).
- `scripts/capture-design.mjs` — headless Chromium capture of every scene at 1x and 2x, light, dark and pair:
  `PLAYWRIGHT_CORE=<path to playwright-core> node scripts/capture-design.mjs [out dir]`. It fails on console errors or
  missing files. Captures are not committed (`build/design-captures`).

Sizes are points: 1 CSS px at 1x = 1 pt in AppKit. Captures on Linux use Noto Sans CJK KR; on a Mac the same CSS uses
SF Pro and Apple SD Gothic Neo, so text widths differ slightly.

Rule: change a value in `tokens.json`, never in `pet.css` or Swift. `pet.css` only uses `var(--…)` for UI values; the
remaining literals are content stand-ins (the capture thumbnail gradient, the gallery page background).
