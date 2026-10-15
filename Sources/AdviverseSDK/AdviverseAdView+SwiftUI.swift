//
//  AdviverseAdView+SwiftUI.swift
//  AdviverseSDK
//
//  SwiftUI wrapper over the UIKit `AdviverseAdView`.
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Declarative banner. `AdviverseBannerView(placement: "home", size: .banner)`
@available(iOS 13.0, *)
public struct AdviverseBannerView: UIViewRepresentable {
    public var placement: String?
    public var size: AdviverseAdSize

    /// - Parameters:
    ///   - placement: placement tag; `nil` uses the configured default tag.
    ///   - size: requested ad size.
    public init(placement: String? = nil, size: AdviverseAdSize = .banner) {
        self.placement = placement
        self.size = size
    }

    public final class Coordinator {
        var loadedPlacement: String?
        var loadedSize: AdviverseAdSize?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> AdviverseAdView {
        let view = AdviverseAdView(size: size)
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.loadedPlacement = placement
        context.coordinator.loadedSize = size
        view.load(placement: placement)
        return view
    }

    public func updateUIView(_ uiView: AdviverseAdView, context: Context) {
        let c = context.coordinator
        guard c.loadedPlacement != placement || c.loadedSize != size else { return }
        c.loadedPlacement = placement
        c.loadedSize = size
        uiView.adSize = size
        uiView.load(placement: placement)
    }
}
#endif
