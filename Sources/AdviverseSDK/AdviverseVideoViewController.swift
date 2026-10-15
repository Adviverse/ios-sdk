//
//  AdviverseVideoViewController.swift
//  AdviverseSDK
//
//  Full-screen linear video presenter (interstitial + rewarded) built on
//  AVPlayer. Plays `AdviverseAd.videoURL` — the hosted asset or the MediaFile
//  resolved from a third-party VAST tag — and fires:
//    • the impression (ours + VAST <Impression>) when playback actually starts,
//    • start / firstQuartile / midpoint / thirdQuartile / complete to our
//      tracking-only `imp_url&ev=…` plus the VAST <Tracking> URLs,
//    • skip (when a skipoffset / skip_offset_sec Skip control is used),
//    • VAST error 405 (playback failure) / 402 (media never started).
//  Taps route through `fireClick()` + `landingURL` (VAST ClickThrough when set).
//

#if canImport(UIKit)
import UIKit
import AVFoundation

final class AdviverseVideoViewController: UIViewController, AdviverseFullscreenCallbacks {

    private let ad: AdviverseAd
    private let url: URL
    private let isRewarded: Bool

    var onImpression: (() -> Void)?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onRewardEarned: (() -> Void)?

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let closeButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    private let ctaButton = UIButton(type: .system)

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var started = false
    private var finished = false
    private var startWatchdog: DispatchWorkItem?

    /// Seconds to wait for the first frame before reporting VAST 402.
    private let startTimeout: TimeInterval = 10

    init?(ad: AdviverseAd, isRewarded: Bool) {
        guard let url = ad.videoURL else { return nil }
        self.ad = ad
        self.url = url
        self.isRewarded = isRewarded
        self.player = AVPlayer(url: url)
        self.playerLayer = AVPlayerLayer(player: player)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    deinit { teardown() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)

        style(closeButton, title: "✕", size: 22)
        closeButton.layer.cornerRadius = 18
        closeButton.isHidden = true
        closeButton.accessibilityLabel = "Close advertisement"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        style(skipButton, title: "", size: 15)
        skipButton.layer.cornerRadius = 6
        skipButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        skipButton.isHidden = true
        skipButton.isEnabled = false
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)

        style(ctaButton, title: ad.creative.cta ?? "Learn more", size: 15)
        ctaButton.layer.cornerRadius = 6
        ctaButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        ctaButton.addTarget(self, action: #selector(adTapped), for: .touchUpInside)

        for b in [closeButton, skipButton, ctaButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(b)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            skipButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            skipButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            ctaButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            ctaButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12)
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(adTapped)))
        observePlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started, !finished else { return }
        player.play()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, !self.started else { return }
            self.fail(402)
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout, execute: watchdog)
        // Stall safety net: a buffering-forever stream must never trap the user.
        let known = ad.vast?.duration ?? ad.creative.duration ?? 30
        DispatchQueue.main.asyncAfter(deadline: .now() + max(known, 15) + 10) { [weak self] in
            self?.closeButton.isHidden = false
        }
    }

    private func style(_ b: UIButton, title: String, size: CGFloat) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: size, weight: .bold)
        b.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    }

    // MARK: Playback observation

    private func observePlayer() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            self?.progress(t.seconds)
        }
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.fail(405) }
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnd), name: .AVPlayerItemDidPlayToEndTime,
                       object: player.currentItem)
        nc.addObserver(self, selector: #selector(didFailToEnd), name: .AVPlayerItemFailedToPlayToEndTime,
                       object: player.currentItem)
    }

    private func progress(_ current: TimeInterval) {
        guard !finished, current.isFinite, current > 0 else { return }
        if !started { didStart() }
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite, duration > 0 {
            let p = current / duration
            if p >= 0.25 { ad.fireVideoEvent("firstQuartile") }
            if p >= 0.50 { ad.fireVideoEvent("midpoint") }
            if p >= 0.75 { ad.fireVideoEvent("thirdQuartile") }
        }
        updateSkip(current)
    }

    private func didStart() {
        started = true
        startWatchdog?.cancel()
        // MRC-style: the impression fires when the first frame actually plays.
        ad.fireImpression()
        Adviverse.registerSKAdNetworkImpression(for: ad)
        ad.fireVideoEvent("start")
        onImpression?()
    }

    /// Skippable (interstitial only — a rewarded ad must be watched): show a
    /// countdown, then an enabled Skip control once the offset elapses.
    private func updateSkip(_ current: TimeInterval) {
        guard !isRewarded, let offset = ad.skipOffset else { return }
        skipButton.isHidden = false
        let remaining = Int(ceil(offset - current))
        if remaining > 0 {
            skipButton.setTitle("Skip in \(remaining)", for: .normal)
            skipButton.isEnabled = false
        } else {
            skipButton.setTitle("Skip ▶", for: .normal)
            skipButton.isEnabled = true
        }
    }

    @objc private func didEnd() {
        guard !finished else { return }
        finished = true
        if !started { didStart() }
        ad.fireVideoEvent("complete")
        skipButton.isHidden = true
        closeButton.isHidden = false
        if isRewarded { onRewardEarned?() }
    }

    @objc private func didFailToEnd() { fail(405) }

    /// Media failure: report the VAST error and let the user leave. No reward.
    private func fail(_ code: Int) {
        guard !finished else { return }
        finished = true
        startWatchdog?.cancel()
        player.pause()
        ad.reportVideoError(code)
        skipButton.isHidden = true
        closeButton.isHidden = false
    }

    // MARK: Actions

    @objc private func adTapped() {
        guard started else { return }
        onClick?()
        ad.fireClick()
        if let url = ad.landingURL { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
    }

    @objc private func skipTapped() {
        ad.fireVideoEvent("skip")
        close()
    }

    @objc private func closeTapped() { close() }

    private func close() {
        finished = true
        teardown()
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }

    private func teardown() {
        startWatchdog?.cancel()
        player.pause()
        if let obs = timeObserver { player.removeTimeObserver(obs); timeObserver = nil }
        statusObservation?.invalidate()
        statusObservation = nil
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Presenter selection (shared by interstitial + rewarded)

extension AdviverseFullscreen {

    /// True when `ad` needs its image preloaded before it is ready: playables
    /// load in a WebView and video streams in AVPlayer at show time.
    static func needsImage(_ ad: AdviverseAd) -> Bool {
        ad.creative.type != "html5" && !ad.isVideo
    }

    /// The full-screen controller for `ad`: playable, video, or static image.
    static func controller(for ad: AdviverseAd, image: UIImage?, closeDelay: TimeInterval,
                           isRewarded: Bool) -> (UIViewController & AdviverseFullscreenCallbacks)? {
        if ad.creative.type == "html5" {
            return AdviversePlayableViewController(ad: ad, closeDelay: closeDelay, isRewarded: isRewarded)
        }
        if let video = AdviverseVideoViewController(ad: ad, isRewarded: isRewarded) { return video }
        guard let image = image else { return nil }
        return AdviverseFullscreenViewController(ad: ad, image: image, closeDelay: closeDelay,
                                                 isRewarded: isRewarded)
    }
}
#endif
