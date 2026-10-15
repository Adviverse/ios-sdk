//
//  AdviversePlayableViewController.swift
//  AdviverseSDK
//
//  Full-screen presenter for a PLAYABLE (interactive HTML5) creative. Instead of
//  a static image it hosts the hosted playable bundle in a WKWebView. The bundle
//  is untrusted third-party code, so it is loaded from the CDN origin and talks
//  to us ONLY through the injected runtime, which posts to the
//  `adviversePlayable` WKScriptMessageHandler installed here. We translate those
//  messages into the SAME tracked impression / click / reward the image
//  presenter uses, so a playable interstitial or rewarded behaves identically to
//  its static counterpart from the app's point of view.
//
//  Message protocol (from the bundle's runtime):
//    { __advPlayable: 1, type: "ready" | "click" | "finish" | "close" }
//

import UIKit
import WebKit

/// The callback surface the full-screen presenters share, so the interstitial
/// and rewarded flows can drive either the image (`AdviverseFullscreenViewController`)
/// or the playable (`AdviversePlayableViewController`) presenter identically.
protocol AdviverseFullscreenCallbacks: AnyObject {
    var onImpression: (() -> Void)? { get set }
    var onClick: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onRewardEarned: (() -> Void)? { get set }
}

final class AdviversePlayableViewController: UIViewController, AdviverseFullscreenCallbacks {

    private let ad: AdviverseAd
    private let closeDelay: TimeInterval
    private let isRewarded: Bool

    var onImpression: (() -> Void)?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    /// Rewarded only: the user completed the experience (the bundle posted
    /// `finish`, or the close delay elapsed as a fallback).
    var onRewardEarned: (() -> Void)?

    private var webView: WKWebView!
    private let closeButton = UIButton(type: .system)
    private var impressionFired = false
    private var rewardEarned = false

    init(ad: AdviverseAd, closeDelay: TimeInterval, isRewarded: Bool) {
        self.ad = ad
        self.closeDelay = closeDelay
        self.isRewarded = isRewarded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // The message handler is the only channel from the (untrusted) creative.
        let contentController = WKUserContentController()
        contentController.add(MessageProxy(self), name: "adviversePlayable")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        // No persistent storage for the ad — matches the web sandbox's spirit.
        if #available(iOS 9.0, *) {
            config.websiteDataStore = .nonPersistent()
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

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
            webView.topAnchor.constraint(equalTo: topGuide),
            webView.bottomAnchor.constraint(equalTo: bottomGuide),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: topGuide, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        if let urlString = ad.creative.assetURL, let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        } else {
            // Nothing to show — dismiss cleanly rather than present a black screen.
            DispatchQueue.main.async { [weak self] in self?.closeTapped() }
        }

        // Fallback reveal of the close button (a broken creative must never trap
        // the user), and the rewarded earned-fallback if `finish` never arrives.
        let delay = max(1, isRewarded ? max(closeDelay, 5) : closeDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.closeButton.isHidden = false
        }
    }

    // MARK: - Bridge messages

    fileprivate func handle(_ type: String) {
        switch type {
        case "ready":
            if !impressionFired {
                impressionFired = true
                ad.fireImpression()
                Adviverse.registerSKAdNetworkImpression(for: ad)
                onImpression?()
            }
        case "click":
            onClick?()
            ad.fireClick()
            if let url = ad.landingURL {
                if #available(iOS 10.0, *) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                } else {
                    UIApplication.shared.openURL(url)
                }
            }
        case "finish":
            if isRewarded && !rewardEarned {
                rewardEarned = true
                onRewardEarned?()
            }
            // Once earned, let the user leave immediately.
            closeButton.isHidden = false
        case "close":
            closeTapped()
        default:
            break
        }
    }

    @objc private func closeTapped() {
        // A rewarded playable that reached its time but never posted `finish`
        // still earns — the user watched long enough (matches the image path).
        if isRewarded && !rewardEarned && !closeButton.isHidden {
            rewardEarned = true
            onRewardEarned?()
        }
        // Tear down the message handler to avoid a retain cycle via the proxy.
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "adviversePlayable")
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}

extension AdviversePlayableViewController: WKNavigationDelegate {
    // Keep the playable contained: only the initial CDN document loads in-frame.
    // Any attempt to navigate the top frame elsewhere (a raw window.location) is
    // treated as a click and opened in the system browser instead.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                if #available(iOS 10.0, *) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Weak trampoline so the WKUserContentController (retained by the config) does
/// not retain the view controller, which would leak it after dismissal.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: AdviversePlayableViewController?
    init(_ target: AdviversePlayableViewController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "adviversePlayable" else { return }
        // The runtime posts an object; read `type`. (WKWebView delivers it as a
        // dictionary.) A string payload is tolerated for defensiveness.
        var type: String?
        if let dict = message.body as? [String: Any] {
            type = dict["type"] as? String
        } else if let s = message.body as? String, let data = s.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            type = dict["type"] as? String
        }
        if let type = type {
            DispatchQueue.main.async { self.target?.handle(type) }
        }
    }
}
