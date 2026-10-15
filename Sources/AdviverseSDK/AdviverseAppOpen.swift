//
//  AdviverseAppOpen.swift
//  AdviverseSDK
//
//  App-open ads: a full-screen ad shown when the user brings the app to the
//  foreground (cold or warm start) — the format AdMob/AppLovin call "app open".
//  It is an interstitial with a foreground trigger and a cooldown, so this is a
//  thin, honest wrapper over AdviverseInterstitial rather than a new renderer.
//
//  Usage:
//      let appOpen = AdviverseAppOpen(placement: "ios-app-open")
//      appOpen.delegate = self
//      appOpen.start()          // preloads, then auto-shows on each foreground
//
//  Or drive it manually with load() + showIfReady(from:).
//

import UIKit

public protocol AdviverseAppOpenDelegate: AnyObject {
    func appOpenDidLoad(_ appOpen: AdviverseAppOpen)
    func appOpen(_ appOpen: AdviverseAppOpen, didFailToLoadWithError error: AdviverseError)
    func appOpenDidPresent(_ appOpen: AdviverseAppOpen)
    func appOpenDidDismiss(_ appOpen: AdviverseAppOpen)
    func appOpenWasClicked(_ appOpen: AdviverseAppOpen)
}

public extension AdviverseAppOpenDelegate {
    func appOpenDidLoad(_ a: AdviverseAppOpen) {}
    func appOpen(_ a: AdviverseAppOpen, didFailToLoadWithError error: AdviverseError) {}
    func appOpenDidPresent(_ a: AdviverseAppOpen) {}
    func appOpenDidDismiss(_ a: AdviverseAppOpen) {}
    func appOpenWasClicked(_ a: AdviverseAppOpen) {}
}

public final class AdviverseAppOpen: NSObject {

    public weak var delegate: AdviverseAppOpenDelegate?

    /// Minimum seconds between two app-open presentations, so returning to the app
    /// repeatedly doesn't spam the user. Default 4 minutes (AdMob's guidance).
    public var minInterval: TimeInterval = 240

    private let placement: String?
    private let interstitial: AdviverseInterstitial
    private var autoShow = false
    private var lastShown: Date?
    private var showing = false

    public init(placement: String? = nil) {
        self.placement = placement
        self.interstitial = AdviverseInterstitial(placement: placement)
        super.init()
        self.interstitial.delegate = self
    }

    public var isReady: Bool { interstitial.isReady }

    /// Preload the app-open ad.
    public func load() { interstitial.load() }

    /// Preload AND auto-present on every subsequent foreground (respecting the
    /// cooldown). Call once, e.g. from application(_:didFinishLaunchingWithOptions:).
    public func start() {
        autoShow = true
        load()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Stop auto-presenting on foreground.
    public func stop() {
        autoShow = false
        NotificationCenter.default.removeObserver(
            self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Present now if an ad is loaded and the cooldown has elapsed.
    @discardableResult
    public func showIfReady(from presenter: UIViewController? = nil) -> Bool {
        guard interstitial.isReady, !showing else { return false }
        if let last = lastShown, Date().timeIntervalSince(last) < minInterval { return false }
        showing = true
        interstitial.show(from: presenter)
        return true
    }

    @objc private func didBecomeActive() {
        guard autoShow else { return }
        // Present on the next runloop so the key window is settled after launch.
        DispatchQueue.main.async { [weak self] in self?.showIfReady() }
    }

    deinit { stop() }
}

extension AdviverseAppOpen: AdviverseInterstitialDelegate {
    public func interstitialDidLoad(_ i: AdviverseInterstitial) {
        delegate?.appOpenDidLoad(self)
        // If a foreground happened before the first load finished, present now.
        if autoShow { DispatchQueue.main.async { [weak self] in self?.showIfReady() } }
    }
    public func interstitial(_ i: AdviverseInterstitial, didFailToLoadWithError error: AdviverseError) {
        showing = false
        delegate?.appOpen(self, didFailToLoadWithError: error)
    }
    public func interstitialDidPresent(_ i: AdviverseInterstitial) {
        lastShown = Date()
        delegate?.appOpenDidPresent(self)
    }
    public func interstitialWasClicked(_ i: AdviverseInterstitial) {
        delegate?.appOpenWasClicked(self)
    }
    public func interstitialDidDismiss(_ i: AdviverseInterstitial) {
        showing = false
        delegate?.appOpenDidDismiss(self)
        // Preload the next one so the following foreground is instant.
        if autoShow { load() }
    }
}
