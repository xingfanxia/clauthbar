import AppKit
import SwiftUI

/// Provider brand glyphs for the tab bar + Overview cards (TABS-1.2) — the
/// actual OpenAI/Anthropic marks instead of stand-in SF Symbols, matching
/// codexbar. The SVGs come from steipete/CodexBar (MIT; see
/// Resources/ICONS-ATTRIBUTION.md) and render as TEMPLATE images so they tint
/// with the surrounding label color (white on the selected pill, secondary
/// when unselected), exactly like codexbar's `ProviderBrandIcon`.
///
/// Loading is dual-path (same pattern as CodexBar's): the packaged .app ships
/// the SVGs in Contents/Resources (package_app.sh copies them — the SPM
/// resource bundle stays dev-only because the FIXTURES in it must not ship),
/// while `swift run`/tests load through `Bundle.module`.
@MainActor
enum ProviderGlyph {
    private static var cache: [Harness: NSImage] = [:]

    private static func resourceName(for harness: Harness) -> String {
        harness == .codex ? "ProviderIcon-codex" : "ProviderIcon-claude"
    }

    /// The harness's brand glyph as a template NSImage, or nil when the
    /// resource is missing (callers fall back to an SF Symbol — a missing
    /// glyph must never blank the tab bar).
    static func image(for harness: Harness) -> NSImage? {
        if let cached = cache[harness] { return cached }
        let name = resourceName(for: harness)
        // Packaged app: Contents/Resources (no SPM bundle ships — fixtures
        // invariant). Dev/tests: the SPM resource bundle.
        let url = Bundle.main.url(forResource: name, withExtension: "svg")
            ?? devBundleURL(name)
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        cache[harness] = image
        return image
    }

    /// `Bundle.module` traps when the resource bundle is absent (the packaged
    /// app) — only touch it when the bundle actually exists on disk.
    private static func devBundleURL(_ name: String) -> URL? {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: name, withExtension: "svg")
    }
}

/// The tab's glyph: the provider brand mark for harness tabs (template-tinted
/// by the current foreground style), the SF grid for Overview, and an SF
/// fallback if a brand SVG ever fails to load.
struct ProviderGlyphView: View {
    let tab: ProviderTab
    var size: CGFloat = 12

    var body: some View {
        if let harness = tab.harness, let image = ProviderGlyph.image(for: harness) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tab.symbol).font(.system(size: size - 1))
        }
    }
}
