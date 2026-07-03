//
//  AdviverseRewarded.swift
//  AdviverseSDK
//
//  Rewarded ad flow. Identical full-screen presentation to the interstitial
//  (it reuses `AdviverseFullscreenViewController`), but the reward is granted
//  only after BOTH: the user completes the ad AND the engine validates the
//  request via the server-verified reward URL modeled on the ad (`reward_url`).
//  The SDK never grants on the client alone.
//

#if canImport(UIKit)
import UIKit

/// The reward granted to the user, as confirmed by the engine.
public struct AdviverseReward: Equatable {
    public let type: String
    public let amount: Int
    public init(type: String = "coins", amount: Int = 1) {
        self.type = type
        self.amount = amount
    }
}

/// Lifecycle callbacks for `AdviverseRewarded`. All methods are optional.
public protocol AdviverseRewardedDelegate: AnyObject {
    func rewardedDidLoad(_ rewarded: AdviverseRewarded)
    func rewarded(_ rewarded: AdviverseRewarded, didFailToLoadWithError error: AdviverseError)
    func rewardedDidPresent(_ rewarded: AdviverseRewarded)
    func rewardedDidDismiss(_ rewarded: AdviverseRewarded)
    func rewardedWasClicked(_ rewarded: AdviverseRewarded)
    /// Called ONLY after the user completed the ad and the engine confirmed the
    /// reward via the server-verified reward URL. Credit the user here.
    func rewarded(_ rewarded: AdviverseRewarded, didGrantReward reward: AdviverseReward)
}

public extension AdviverseRewardedDelegate {
    func rewardedDidLoad(_ r: AdviverseRewarded) {}
    func rewarded(_ r: AdviverseRewarded, didFailToLoadWithError error: AdviverseError) {}
    func rewardedDidPresent(_ r: AdviverseRewarded) {}
    func rewardedDidDismiss(_ r: AdviverseRewarded) {}
    func rewardedWasClicked(_ r: AdviverseRewarded) {}
    func rewarded(_ r: AdviverseRewarded, didGrantReward reward: AdviverseReward) {}
}

/// A preloadable full-screen rewarded ad.
///
///     let rewarded = AdviverseRewarded(placement: "ios-rewarded")
///     rewarded.delegate = self
///     rewarded.load()
///     // later, once `isReady`:
///     rewarded.show()
///
public final class AdviverseRewarded: NSObject {

    public weak var delegate: AdviverseRewardedDelegate?

    private let placement: String?
    private var ad: AdviverseAd?
    private var preloadedImage: UIImage?
    private var rewardEarnedLocally = false

    /// Create a rewarded ad for `placement` (falls back to the configured tag).
    public init(placement: String? = nil) {
        self.placement = placement
        super.init()
    }

    /// True once both the ad and its creative image have been preloaded.
    public var isReady: Bool { ad != nil && preloadedImage != nil }

    /// Preload the rewarded ad. Call `show()` once `isReady` (or wait for
    /// `rewardedDidLoad`).
    public func load() {
        Adviverse.loadAd(placement: placement, size: .fullScreen, format: .rewarded) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.rewarded(self, didFailToLoadWithError: error)
            case .success(let ad):
                self.ad = ad
                AdviverseFullscreen.preloadImage(for: ad) { [weak self] image in
                    guard let self = self else { return }
                    guard let image = image else {
                        self.ad = nil
                        self.delegate?.rewarded(self, didFailToLoadWithError: .invalidResponse)
                        return
                    }
                    self.preloadedImage = image
                    self.delegate?.rewardedDidLoad(self)
                }
            }
        }
    }

    /// Present the full-screen rewarded ad. Pass an explicit presenter, or let
    /// the SDK resolve the top-most view controller over the key window.
    public func show(from presenter: UIViewController? = nil) {
        guard let ad = ad, let image = preloadedImage else {
            delegate?.rewarded(self, didFailToLoadWithError: .invalidResponse)
            return
        }
        guard let host = presenter ?? AdviverseFullscreen.topViewController() else {
            delegate?.rewarded(self, didFailToLoadWithError: .invalidResponse)
            return
        }
        rewardEarnedLocally = false
        let vc = AdviverseFullscreenViewController(ad: ad, image: image,
                                                   closeDelay: 0, isRewarded: true)
        vc.modalPresentationStyle = .fullScreen
        vc.onImpression = { [weak self] in
            guard let self = self else { return }
            self.delegate?.rewardedDidPresent(self)
        }
        vc.onClick = { [weak self] in
            guard let self = self else { return }
            self.delegate?.rewardedWasClicked(self)
        }
        // Earned locally = the user watched to completion. We do NOT grant yet;
        // we wait for server validation, which happens on dismiss.
        vc.onRewardEarned = { [weak self] in
            self?.rewardEarnedLocally = true
        }
        vc.onClose = { [weak self] in
            guard let self = self else { return }
            self.delegate?.rewardedDidDismiss(self)
            self.consumeAndMaybeGrant(ad: ad)
        }
        host.present(vc, animated: true)
    }

    /// On dismiss: if the user earned the reward locally, hit the engine's
    /// reward URL. The engine re-verifies the request server-side (the
    /// authoritative grant) — only on a confirmed 2xx do we notify the host.
    private func consumeAndMaybeGrant(ad: AdviverseAd) {
        let earned = rewardEarnedLocally
        self.ad = nil
        self.preloadedImage = nil
        guard earned else { return }
        Adviverse.grantReward(for: ad) { [weak self] confirmed in
            guard let self = self, confirmed else { return }
            self.delegate?.rewarded(self, didGrantReward: AdviverseReward())
        }
    }
}
#endif

// MARK: - Server-verified reward grant

extension Adviverse {

    /// Hit the ad's server-verified `reward_url`. The engine re-validates the
    /// request and is the authoritative grant; `completion(true)` is delivered
    /// on the main queue only on a confirmed 2xx. No-ops (false) when the ad
    /// carries no reward URL. Never call this until the user genuinely completed
    /// the ad.
    static func grantReward(for ad: AdviverseAd, completion: @escaping (Bool) -> Void) {
        func finish(_ ok: Bool) {
            if Thread.isMainThread { completion(ok) }
            else { DispatchQueue.main.async { completion(ok) } }
        }
        guard let path = ad.rewardURL, !path.isEmpty,
              let url = Adviverse.absoluteURL(path, base: ad.baseURL) else {
            finish(false)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let task = URLSession.shared.dataTask(with: req) { _, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            finish(ok)
        }
        task.resume()
    }
}
