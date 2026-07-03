//
//  AdviverseAdView.swift
//  AdviverseSDK
//
//  A minimal drop-in UIKit banner view. Hand it a placement + size and it loads
//  an ad, renders the image creative, fires the impression when it appears on
//  screen, and on tap fires the click beacon and opens the advertiser landing
//  page. For full-screen / native / video formats use `Adviverse.loadAd`
//  directly and render with your own presentation.
//

#if canImport(UIKit)
import UIKit

/// Optional lifecycle callbacks for `AdviverseAdView`.
public protocol AdviverseAdViewDelegate: AnyObject {
    func adViewDidReceiveAd(_ adView: AdviverseAdView, ad: AdviverseAd)
    func adView(_ adView: AdviverseAdView, didFailToReceiveAdWithError error: AdviverseError)
    func adViewDidRecordImpression(_ adView: AdviverseAdView)
    func adViewDidRecordClick(_ adView: AdviverseAdView)
}

/// Default no-op implementations so conformers implement only what they need.
public extension AdviverseAdViewDelegate {
    func adViewDidReceiveAd(_ adView: AdviverseAdView, ad: AdviverseAd) {}
    func adView(_ adView: AdviverseAdView, didFailToReceiveAdWithError error: AdviverseError) {}
    func adViewDidRecordImpression(_ adView: AdviverseAdView) {}
    func adViewDidRecordClick(_ adView: AdviverseAdView) {}
}

public final class AdviverseAdView: UIView {

    // MARK: Public

    public weak var delegate: AdviverseAdViewDelegate?

    /// The currently displayed ad, if any.
    public private(set) var ad: AdviverseAd?

    /// The size used for the request / intrinsic content size.
    public var adSize: AdviverseAdSize {
        didSet { invalidateIntrinsicContentSize() }
    }

    // MARK: Private

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.isUserInteractionEnabled = false
        return iv
    }()

    private var imageTask: URLSessionDataTask?
    private var impressionFired = false

    // MARK: Init

    public init(size: AdviverseAdSize = .banner) {
        self.adSize = size
        super.init(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.adSize = .banner
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Advertisement"
    }

    // MARK: Loading

    /// Load an ad for `placement` (falls back to the configured tag) and render
    /// it. The impression fires automatically once the creative is on screen.
    public func load(placement: String? = nil) {
        Adviverse.loadAd(placement: placement, size: adSize, format: .banner) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let ad):
                self.render(ad)
                self.delegate?.adViewDidReceiveAd(self, ad: ad)
            case .failure(let error):
                self.delegate?.adView(self, didFailToReceiveAdWithError: error)
            }
        }
    }

    /// Render an already-loaded ad (e.g. fetched via `Adviverse.loadAd`).
    public func render(_ ad: AdviverseAd) {
        self.ad = ad
        self.impressionFired = false
        accessibilityLabel = ad.creative.brandName.map { "Advertisement: \($0)" } ?? "Advertisement"
        loadImage(ad.creative.bannerImageURL)
        // If we're already visible, count the impression now; otherwise it fires
        // from didMoveToWindow.
        fireImpressionIfVisible()
    }

    private func loadImage(_ urlString: String?) {
        imageTask?.cancel()
        imageView.image = nil
        guard let urlString = urlString, let url = URL(string: urlString) else { return }
        imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.imageView.image = image
                self.fireImpressionIfVisible()
            }
        }
        imageTask?.resume()
    }

    // MARK: Impression

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        fireImpressionIfVisible()
    }

    private func fireImpressionIfVisible() {
        guard !impressionFired,
              window != nil,
              imageView.image != nil,
              let ad = ad else { return }
        impressionFired = true
        ad.fireImpression()
        delegate?.adViewDidRecordImpression(self)
    }

    // MARK: Click

    @objc private func handleTap() {
        guard let ad = ad else { return }
        // Fire the click beacon, then open the landing URL. The /click endpoint
        // records the click and 302-redirects to the advertiser, so opening it
        // both counts and navigates.
        ad.fireClick()
        delegate?.adViewDidRecordClick(self)
        if let url = ad.landingURL {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
        }
    }

    // MARK: Layout

    public override var intrinsicContentSize: CGSize {
        guard adSize.width > 0, adSize.height > 0 else { return super.intrinsicContentSize }
        return CGSize(width: adSize.width, height: adSize.height)
    }

    deinit {
        imageTask?.cancel()
    }
}
#endif
