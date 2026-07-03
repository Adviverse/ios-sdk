//
//  AdviverseInterstitial.swift
//  AdviverseSDK
//
//  Full-screen interstitial presenter. Preloads an interstitial creative via
//  the shared `Adviverse.loadAd` API, then presents a modal view controller that
//  renders the creative full-bleed, fires the impression (and the SKAdNetwork
//  view-through, when the engine signed one) on appear, reveals a close button
//  after a delay, and routes taps through the ad's click beacon + landing page.
//
//  The networking/identity/beacon logic is NOT duplicated here — this file only
//  adds the presentation layer on top of the existing `AdviverseAd` model. The
//  shared `AdviverseFullscreenViewController` below is reused by the rewarded
//  presenter (`AdviverseRewarded.swift`).
//

#if canImport(UIKit)
import UIKit

/// Lifecycle callbacks for `AdviverseInterstitial`. All methods are optional.
public protocol AdviverseInterstitialDelegate: AnyObject {
    /// The interstitial loaded and its creative is ready to show.
    func interstitialDidLoad(_ interstitial: AdviverseInterstitial)
    /// Loading failed (`.noFill` is the benign "no ad" outcome).
    func interstitial(_ interstitial: AdviverseInterstitial, didFailToLoadWithError error: AdviverseError)
    /// The interstitial was presented and the impression was recorded.
    func interstitialDidPresent(_ interstitial: AdviverseInterstitial)
    /// The user dismissed the interstitial.
    func interstitialDidDismiss(_ interstitial: AdviverseInterstitial)
    /// The user tapped the creative.
    func interstitialWasClicked(_ interstitial: AdviverseInterstitial)
}

public extension AdviverseInterstitialDelegate {
    func interstitialDidLoad(_ i: AdviverseInterstitial) {}
    func interstitial(_ i: AdviverseInterstitial, didFailToLoadWithError error: AdviverseError) {}
    func interstitialDidPresent(_ i: AdviverseInterstitial) {}
    func interstitialDidDismiss(_ i: AdviverseInterstitial) {}
    func interstitialWasClicked(_ i: AdviverseInterstitial) {}
}

/// A preloadable full-screen interstitial.
///
///     let interstitial = AdviverseInterstitial(placement: "ios-interstitial")
///     interstitial.delegate = self
///     interstitial.load()
///     // later, once `isReady`:
///     interstitial.show()
///
public final class AdviverseInterstitial: NSObject {

    public weak var delegate: AdviverseInterstitialDelegate?

    /// Seconds before the close button appears. 0 = immediately closeable.
    public var closeDelay: TimeInterval = 2

    private let placement: String?
    private var ad: AdviverseAd?
    private var preloadedImage: UIImage?

    /// Create an interstitial for `placement` (falls back to the configured tag).
    public init(placement: String? = nil) {
        self.placement = placement
        super.init()
    }

    /// True once both the ad and its creative image have been preloaded.
    public var isReady: Bool { ad != nil && preloadedImage != nil }

    /// Preload the interstitial. Call `show()` once `isReady` (or wait for
    /// `interstitialDidLoad`).
    public func load() {
        Adviverse.loadAd(placement: placement, size: .fullScreen, format: .interstitial) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.interstitial(self, didFailToLoadWithError: error)
            case .success(let ad):
                self.ad = ad
                AdviverseFullscreen.preloadImage(for: ad) { [weak self] image in
                    guard let self = self else { return }
                    guard let image = image else {
                        self.ad = nil
                        self.delegate?.interstitial(self, didFailToLoadWithError: .invalidResponse)
                        return
                    }
                    self.preloadedImage = image
                    self.delegate?.interstitialDidLoad(self)
                }
            }
        }
    }

    /// Present the full-screen ad. Pass an explicit presenter, or let the SDK
    /// resolve the top-most view controller over the key window.
    public func show(from presenter: UIViewController? = nil) {
        guard let ad = ad, let image = preloadedImage else {
            delegate?.interstitial(self, didFailToLoadWithError: .invalidResponse)
            return
        }
        guard let host = presenter ?? AdviverseFullscreen.topViewController() else {
            delegate?.interstitial(self, didFailToLoadWithError: .invalidResponse)
            return
        }
        let vc = AdviverseFullscreenViewController(ad: ad, image: image,
                                                   closeDelay: closeDelay, isRewarded: false)
        vc.modalPresentationStyle = .fullScreen
        vc.onImpression = { [weak self] in
            guard let self = self else { return }
            self.delegate?.interstitialDidPresent(self)
        }
        vc.onClick = { [weak self] in
            guard let self = self else { return }
            self.delegate?.interstitialWasClicked(self)
        }
        vc.onClose = { [weak self] in
            guard let self = self else { return }
            self.delegate?.interstitialDidDismiss(self)
            // Consume the ad; a fresh load() is required for the next show.
            self.ad = nil
            self.preloadedImage = nil
        }
        host.present(vc, animated: true)
    }
}

// MARK: - Shared full-screen renderer (used by interstitial + rewarded)

/// Renders a preloaded creative image full-bleed, fires the impression (and the
/// SKAdNetwork view-through) on appear, reveals a close button after a delay,
/// and routes taps through the ad's click beacon + landing page.
final class AdviverseFullscreenViewController: UIViewController {

    private let ad: AdviverseAd
    private let image: UIImage
    private let closeDelay: TimeInterval
    private let isRewarded: Bool

    var onImpression: (() -> Void)?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    /// Rewarded only: fired once the user has watched long enough to earn it.
    var onRewardEarned: (() -> Void)?

    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private var impressionFired = false
    private var rewardEarned = false

    init(ad: AdviverseAd, image: UIImage, closeDelay: TimeInterval, isRewarded: Bool) {
        self.ad = ad
        self.image = image
        self.closeDelay = closeDelay
        self.isRewarded = isRewarded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 18
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        closeButton.accessibilityLabel = "Close advertisement"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        let topGuide: NSLayoutYAxisAnchor
        let bottomGuide: NSLayoutYAxisAnchor
        if #available(iOS 11.0, *) {
            topGuide = view.safeAreaLayoutGuide.topAnchor
            bottomGuide = view.safeAreaLayoutGuide.bottomAnchor
        } else {
            topGuide = topLayoutGuide.bottomAnchor
            bottomGuide = bottomLayoutGuide.topAnchor
        }

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topGuide),
            imageView.bottomAnchor.constraint(equalTo: bottomGuide),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: topGuide, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(adTapped))
        imageView.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !impressionFired {
            impressionFired = true
            ad.fireImpression()
            // Register the StoreKit view-through impression when the engine
            // supplied a signed SKAdNetwork payload (install campaigns). No-op
            // otherwise. The signature is server-generated (see
            // AdviverseSKAdNetwork.swift).
            Adviverse.registerSKAdNetworkImpression(for: ad)
            onImpression?()
        }
        // Reveal the close button after the delay. For rewarded, the delay also
        // gates when the reward is considered earned (proxy for "ad completed").
        let delay = max(0, isRewarded ? max(closeDelay, rewardDuration()) : closeDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.closeButton.isHidden = false
            if self.isRewarded && !self.rewardEarned {
                self.rewardEarned = true
                self.onRewardEarned?()
            }
        }
    }

    /// For rewarded video, the creative `duration` defines completion time.
    private func rewardDuration() -> TimeInterval {
        if let d = ad.creative.duration, d > 0 { return TimeInterval(d) }
        return 5
    }

    @objc private func adTapped() {
        onClick?()
        // Fire the click beacon, then open the landing page. The /click endpoint
        // records the click and 302-redirects to the advertiser, so opening it
        // both counts and navigates.
        ad.fireClick()
        if let url = ad.landingURL {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}

// MARK: - Presentation helpers

/// Small helpers shared by the full-screen presenters: image preloading and
/// resolving the top-most view controller to present over.
enum AdviverseFullscreen {

    /// Download and decode the best creative image for `ad` off the main thread,
    /// delivering the result (or nil) on the main queue.
    static func preloadImage(for ad: AdviverseAd, completion: @escaping (UIImage?) -> Void) {
        guard let urlString = ad.creative.bannerImageURL, let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { completion(image) }
        }
        task.resume()
    }

    /// Resolve the top-most presented view controller over the active key window,
    /// so callers can present without threading a presenter through their own UI.
    static func topViewController() -> UIViewController? {
        guard var top = keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private static func keyWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            return windows.first { $0.isKeyWindow } ?? windows.first
        } else {
            return UIApplication.shared.keyWindow
        }
    }
}
#endif
