import AppKit
import SwiftUI

enum TokenProvider: String, CaseIterable, Identifiable {
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        }
    }

    var shortName: String {
        switch self {
        case .codex:
            return "Codex"
        }
    }

    var resourceName: String {
        switch self {
        case .codex:
            return "codex"
        }
    }

}

enum ProviderIcon {
    static func image(for provider: TokenProvider) -> NSImage {
        let cacheKey = provider.rawValue
        if let cached = cache[cacheKey] {
            return cached
        }

        let image: NSImage
        if
            let url = Bundle.module.url(forResource: provider.resourceName, withExtension: "svg"),
            let loaded = NSImage(contentsOf: url)
        {
            image = loaded
        } else if let fallback = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil) {
            image = fallback
        } else {
            image = NSImage(size: NSSize(width: 16, height: 16))
        }

        image.isTemplate = true
        cache[cacheKey] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]
}

struct ProviderIconView: View {
    let provider: TokenProvider
    var size: CGFloat = 14

    var body: some View {
        Image(nsImage: ProviderIcon.image(for: provider))
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
