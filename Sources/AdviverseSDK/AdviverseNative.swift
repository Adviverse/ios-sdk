//
//  AdviverseNative.swift
//  AdviverseSDK
//
//  Native ads. Unlike banner/interstitial/rewarded, a native ad is NOT rendered
//  by the SDK — the engine returns the structured creative fields (title, body,
//  icon, main image, CTA, brand) and the host app lays them out in its own UI to
//  match its design. The SDK still owns tracking: call `registerView` once the
//  ad is on screen to fire the impression, and it routes taps on the
//  caller-provided views through the ad's click beacon + landing page.
//
//  No networking is duplicated here: loading reuses `Adviverse.loadAd` and
//  tracking reuses `AdviverseAd.fireImpression()` / `fireClick()`.
//

import Foundation

/// A loaded native ad. The host app reads the asset fields, renders them in its
/// own layout, then registers the container view for impression/click tracking.
public final class AdviverseNativeAd {

    /// The underlying engine response (request id + beacons + creative).
    public let ad: AdviverseAd

    // Convenience accessors for the fields a host layout typically needs.
    public var title: String? { ad.creative.title }
    public var body: String? { ad.creative.description }
    public var iconURL: String? { ad.creative.iconURL }
    public var mainImageURL: String? { ad.creative.mainImageURL ?? ad.creative.assetURL }
    public var callToAction: String? { ad.creative.cta }
    public var brandName: String? { ad.creative.brandName }
    /// The destination to open on tap (the engine's `/click` URL, which records
    /// the click and 302-redirects to the advertiser landing page).
    public var landingURL: URL? { ad.landingURL }

    private var impressionFired = false

    public init(ad: AdviverseAd) {
        self.ad = ad
    }

    /// Convenience loader: fetch a native ad for `placement` (falls back to the
    /// configured tag). Delivers `nil` on no-fill, an error otherwise. Completion
    /// is on the main queue.
    public static func load(placement: String? = nil,
                            completion: @escaping (Result<AdviverseNativeAd?, AdviverseError>) -> Void) {
        Adviverse.loadAd(placement: placement, size: .fullScreen, format: .native) { result in
            switch result {
            case .success(let ad):
                completion(.success(AdviverseNativeAd(ad: ad)))
            case .failure(.noFill):
                completion(.success(nil))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// async/await convenience loader. Returns `nil` on no-fill.
    @available(iOS 13.0, *)
    public static func load(placement: String? = nil) async throws -> AdviverseNativeAd? {
        try await withCheckedThrowingContinuation { continuation in
            load(placement: placement) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Fire the impression beacon exactly once per ad instance. Call once the
    /// native ad's container is actually on screen.
    public func registerViewForImpression() {
        guard !impressionFired else { return }
        impressionFired = true
        ad.fireImpression()
    }

    /// Fire the click beacon and return the landing URL the host should open.
    /// (`AdviverseAd.fireClick()` is idempotent, so this is safe to call once
    /// per tap.)
    @discardableResult
    public func handleClick() -> URL? {
        ad.fireClick()
        return ad.landingURL
    }
}

#if canImport(UIKit)
import UIKit

public extension AdviverseNativeAd {
    /// Wire a host view tree for tracking. Fires the impression immediately if
    /// `containerView` is already in a window (else on the next attach), and
    /// attaches a tap recognizer to each of `clickableViews` that fires the click
    /// beacon and opens the landing page.
    func register(containerView: UIView, clickableViews: [UIView]) {
        if containerView.window != nil { registerViewForImpression() }
        for v in clickableViews {
            v.isUserInteractionEnabled = true
            let tap = AdviverseNativeTapRecognizer(target: AdviverseNativeTapTarget.shared,
                                                   action: #selector(AdviverseNativeTapTarget.fire(_:)))
            tap.nativeAd = self
            v.addGestureRecognizer(tap)
        }
    }
}

/// Tap recognizer carrying a ref to the native ad so the shared gesture target
/// can route the click without the host retaining extra state.
private final class AdviverseNativeTapRecognizer: UITapGestureRecognizer {
    weak var nativeAd: AdviverseNativeAd?
}

private final class AdviverseNativeTapTarget {
    static let shared = AdviverseNativeTapTarget()
    @objc func fire(_ recognizer: UIGestureRecognizer) {
        guard let r = recognizer as? AdviverseNativeTapRecognizer, let ad = r.nativeAd else { return }
        guard let url = ad.handleClick() else { return }
        if #available(iOS 10.0, *) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else {
            UIApplication.shared.openURL(url)
        }
    }
}
#endif
