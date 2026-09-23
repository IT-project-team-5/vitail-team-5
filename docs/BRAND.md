# Vitail visual identity

The approved mark retains the left-facing golden retriever silhouette and its
curved ear cutout. The enlarged silhouette fills the lower portion of the image,
with a cursive lowercase `vitail` wordmark behind it on a full-bleed cream
background. There is no drawn outer frame or baked-in rounded corner mask.
This revised artwork was approved on 23 September 2026 and resized to a
1024 × 1024 opaque RGB PNG without changing its composition. The same image is
included as `Assets.xcassets/AppIcon.appiconset` for the Home Screen and
`BrandMark.imageset` for the sign-in screen. The system applies the Home Screen
icon mask; the in-app brand component applies its own rounded clipping shape.

The shared palette lives in `Core/DesignSystem/AppTheme.swift`:

| Role | Light | Dark |
| --- | --- | --- |
| Interactive brand | #8A561C | #E3AD58 |
| Button label | #FFFFFF | #281A0D |
| Background | #FFF8EA | #211B15 |
| Surface / card | #FFFDF7 | #30261D |
| Main text | #432D1B | #FFF2DB |
| Secondary text | #786149 | #D4BFA0 |
| Border | #DDC9A9 | #685440 |

The artwork's honey gold (approximately #B77B28) is intentionally not the small
text color. The interactive palette is darker in light mode for readability.
Colors adapt to system appearance rather than forcing light mode. Error red,
warning amber, success green, and location blue remain semantic colors, paired
with text or symbols. Map route lines use the brand color; finish markers use
success green and a distinct marker shape. MapKit's map and location dot retain
their native appearance.

`BrandAppearanceTests` checks primary icon packaging, brand-image loading and
4.5:1 contrast for enabled standard text/button combinations in both appearances.
It also attaches light/dark login, Walk component and button-state snapshots,
plus large-text login and light/dark café product snapshots at standard and
accessibility text sizes. Snapshot data comes from local fixtures; no GPS
recordings, awarded walks or menu changes are created.
This is not a claim of a full accessibility audit.

Shared form prompts use the secondary text color. Account choices and primary
buttons can grow vertically for larger system text instead of truncating labels.
Verification on 23 September 2026, including café product management: the iOS
Simulator test suite passed with 181 tests passed, 1 device-only test skipped
and no failures. The iPhone Release build passed with signing disabled.
Light/dark and large-text captures were visually reviewed; this does not replace
real-device appearance or signing checks.

The flat AppIcon uses Xcode's single-size asset support. The system generates
required sizes; no custom layered Icon Composer, dark-icon or tinted-icon artwork
is supplied. See [Apple's asset-catalog icon guide](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).

This change affects presentation and resources only; it does not change walking,
authentication, reward rules, database schema or server configuration.
