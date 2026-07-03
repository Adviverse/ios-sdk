//
//  Adviverse.swift
//  AdviverseSDK
//
//  Native iOS client for the Adviverse ad network `/mobile/ad` endpoint.
//
//  The endpoint (services/ad-engine/internal/server/mobile.go) takes in-app
//  signals — the device advertising id (`ifa`), limit-ad-tracking (`lmt`), app
//  bundle/name, device make/model/os, the requested `format`, plus the shared
//  identity + consent params the web path uses (`uid`, `gdpr_consent`,
//  `us_privacy`, `em`). It returns the standard ad JSON plus mobile extensions:
//  an SKAdNetwork block (iOS) and a rewarded-video reward callback URL.
//
//  This file is the public surface: configuration, the decoded ad model, the
//  loaders (async + completion), the impression/click beacons, identity/consent
//  handling and SKAdNetwork passthrough. The drop-in banner view lives in
//  `AdviverseAdView.swift`.
//

import Foundation
import CryptoKit

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - Public errors

/// Failure modes surfaced by `loadAd`. `.noFill` is the expected "no ad this
/// time" outcome (HTTP 204) — treat it as benign, not an error to log loudly.
public enum AdviverseError: Error {
    case notConfigured        // configure(tag:) was never called
    case missingTag           // no placement tag available
    case noFill               // server returned 204 (no ad / version-gated)
    case badStatus(Int)       // non-2xx, non-204 HTTP status
    case invalidResponse      // missing/empty body
    case decoding(Error)      // JSON did not match the contract
    case network(Error)       // transport-level failure
}

// MARK: - Sizes & formats

/// A requested creative size in points. Presets cover the common IAB units; the
/// width/height are forwarded to the server as `w`/`h` for size-aware selection.
public struct AdviverseAdSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let banner          = AdviverseAdSize(width: 320, height: 50)
    public static let largeBanner     = AdviverseAdSize(width: 320, height: 100)
    public static let mediumRectangle = AdviverseAdSize(width: 300, height: 250)
    public static let leaderboard     = AdviverseAdSize(width: 728, height: 90)
    /// Full-screen formats (interstitial / rewarded) do not pin a size.
    public static let fullScreen      = AdviverseAdSize(width: 0, height: 0)
}

/// The ad format requested via the `format` query param. Mirrors the server's
/// accepted set: interstitial | rewarded | banner | native | video.
public enum AdviverseFormat: String {
    case banner
    case interstitial
    case rewarded
    case native
    case video
}

// MARK: - Ad model

/// A creative as returned in the response `creative` object. Field names mirror
/// `buildCreativePayload` in the engine exactly. Most fields are optional because
/// which ones are populated depends on the creative `type` (image banner vs
/// native vs video).
public struct AdviverseCreative: Decodable {
    public let id: String?
    public let type: String?
    public let assetURL: String?
    public let title: String?
    public let description: String?
    public let iconURL: String?
    public let mainImageURL: String?
    public let cta: String?
    public let brandName: String?
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let skipOffsetSec: Int?
    public let vpaidURL: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, description, cta, width, height, duration
        case assetURL = "asset_url"
        case iconURL = "icon_url"
        case mainImageURL = "main_image_url"
        case brandName = "brand_name"
        case skipOffsetSec = "skip_offset_sec"
        case vpaidURL = "vpaid_url"
    }

    /// Best image to render for a banner: the explicit main image, else the
    /// generic asset, else the icon.
    public var bannerImageURL: String? {
        mainImageURL ?? assetURL ?? iconURL
    }
}

/// The SKAdNetwork attribution block (iOS only). Surfaced verbatim so an
/// integrator can drive StoreKit (`SKAdNetwork.updateConversionValue` etc.).
///
/// IMPORTANT: when `signaturePlaceholder == true` the `signature` is NOT a
/// valid Apple signature — a production-attributable value must be produced
/// server-side by signing Apple's field ordering with the network's SKAdNetwork
/// private key. Do not submit a placeholder-signed payload to StoreKit expecting
/// attribution; use it only to wire up the integration in non-production.
public struct AdviverseSKAdNetwork: Decodable {
    public let version: String
    public let network: String
    public let campaign: String
    public let sourceIdentifier: String
    public let itunesItem: String
    public let sourceApp: String?
    public let fidelityType: String?
    public let nonce: String
    public let timestamp: Int64
    public let signature: String
    public let signaturePlaceholder: Bool

    enum CodingKeys: String, CodingKey {
        case version, network, campaign, nonce, timestamp, signature
        case sourceIdentifier = "source_identifier"
        case itunesItem = "itunesitem"
        case sourceApp = "sourceapp"
        case fidelityType = "fidelity_type"
        case signaturePlaceholder = "signature_placeholder"
    }

    /// True only when the server signed with a real key. Gate any StoreKit
    /// attribution call on this.
    public var isSigned: Bool { !signaturePlaceholder }

    /// The dictionary an iOS app passes to StoreKit's attribution APIs, with
    /// Apple's canonical key names.
    public var attributionDictionary: [String: Any] {
        var d: [String: Any] = [
            "version": version,
            "network": network,
            "campaign": campaign,
            "source-identifier": sourceIdentifier,
            "itunes-item-identifier": itunesItem,
            "nonce": nonce,
            "timestamp": String(timestamp),
            "signature": signature
        ]
        if let sourceApp = sourceApp, !sourceApp.isEmpty {
            d["source-app-store-item-identifier"] = sourceApp
        }
        if let fidelityType = fidelityType, !fidelityType.isEmpty {
            d["fidelity-type"] = fidelityType
        }
        return d
    }
}

/// A served ad. `fireImpression()` / `fireClick()` send the engine's beacons.
/// Both beacon URLs arrive from the server as relative paths (`/imp?rid=…`,
/// `/click?rid=…`) and are resolved against the configured base URL.
public struct AdviverseAd: Decodable {
    public let requestID: String
    public let format: String
    public let creative: AdviverseCreative
    /// Relative impression beacon path as returned by the server.
    public let impressionPath: String
    /// Relative click beacon path as returned by the server.
    public let clickPath: String
    public let viewablePath: String?
    public let predictedViewability: Double?
    public let skAdNetwork: AdviverseSKAdNetwork?
    public let rewardURL: String?

    /// Set by the loader after decode so the beacons can be made absolute.
    /// Internal: not part of the wire contract.
    internal var baseURL: URL?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case format, creative
        case impressionPath = "imp_url"
        case clickPath = "click_url"
        case viewablePath = "viewable_url"
        case predictedViewability = "predicted_viewability"
        case skAdNetwork = "skadn"
        case rewardURL = "reward_url"
    }

    /// Absolute impression beacon URL (relative path resolved against base).
    public var impressionURL: URL? { Adviverse.absoluteURL(impressionPath, base: baseURL) }
    /// Absolute click beacon URL.
    public var clickURL: URL? { Adviverse.absoluteURL(clickPath, base: baseURL) }
    /// Absolute viewability beacon base, if the server supplied one.
    public var viewableURL: URL? {
        guard let viewablePath = viewablePath, !viewablePath.isEmpty else { return nil }
        return Adviverse.absoluteURL(viewablePath, base: baseURL)
    }

    /// The destination an integrator should open when the user taps the ad. The
    /// engine's `/click` beacon both records the click and 302-redirects to the
    /// advertiser landing page, so opening this URL counts the click *and*
    /// navigates — no separate redirect handling required.
    public var landingURL: URL? { clickURL }

    // Impression/click are billable; the SDK fires each at most once per ad
    // instance. A reference type box guards against accidental double counting.
    private let fireState = FireState()

    /// Send the impression beacon (idempotent per ad instance). Call when the
    /// creative is actually on screen.
    public func fireImpression() {
        guard fireState.markImpression(), let url = impressionURL else { return }
        Adviverse.sendBeacon(url)
    }

    /// Send the click beacon (idempotent per ad instance). Call on tap. To also
    /// navigate the user, open `landingURL` (which is the same `/click` URL and
    /// redirects to the advertiser) — opening it is sufficient and will record
    /// the click on its own, but calling this guarantees a beacon even if the
    /// open is blocked.
    public func fireClick() {
        guard fireState.markClick() else { return }
        guard let url = clickURL else { return }
        Adviverse.sendBeacon(url)
    }

    private final class FireState {
        private let lock = NSLock()
        private var impressionFired = false
        private var clickFired = false
        func markImpression() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if impressionFired { return false }
            impressionFired = true; return true
        }
        func markClick() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if clickFired { return false }
            clickFired = true; return true
        }
    }
}

// MARK: - SDK entry point

/// `Adviverse` is the configured singleton entry point. Configure once at
/// launch, then call `loadAd`.
///
///     Adviverse.configure(tag: "ios-banner-home")
///     Adviverse.loadAd(size: .banner) { result in … }
///
public final class Adviverse {

    /// SemVer of this SDK, sent as `v` alongside `client=ios-sdk` so the engine's
    /// version gate can no-fill an outdated/exploitable build.
    public static let version = "1.0.0"
    private static let clientName = "ios-sdk"

    /// Default serving host. Override via `configure(baseURL:)` for staging or a
    /// custom edge domain.
    public static let defaultBaseURL = URL(string: "https://serve.adviverse.com")!

    /// The process-wide shared instance.
    public static let shared = Adviverse()

    // Mutable config is guarded by `lock`; reads/writes are short and rare.
    private let lock = NSLock()
    private var configuredTag: String?
    private var baseURL: URL = Adviverse.defaultBaseURL
    private var gdprConsent: String?
    private var usPrivacy: String?
    private var emailHash: String?

    private let session: URLSession
    private let defaults = UserDefaults.standard
    private static let uidKey = "com.adviverse.sdk.uid"

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Configuration

    /// Configure the SDK with the default placement tag and (optionally) a base
    /// URL. Call once, early (e.g. in `application(_:didFinishLaunching…)`).
    public static func configure(tag: String, baseURL: URL? = nil) {
        shared.configure(tag: tag, baseURL: baseURL)
    }

    public func configure(tag: String, baseURL: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.configuredTag = tag
        if let baseURL = baseURL { self.baseURL = baseURL }
    }

    /// Set the GDPR TCF consent string and/or the US-privacy (CCPA) string. Both
    /// are forwarded unmodified as `gdpr_consent` / `us_privacy`. Pass `nil` to
    /// leave a value unchanged; pass `""` to clear it.
    public static func setConsent(gdpr: String? = nil, usPrivacy: String? = nil) {
        shared.setConsent(gdpr: gdpr, usPrivacy: usPrivacy)
    }

    public func setConsent(gdpr: String? = nil, usPrivacy: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let gdpr = gdpr { self.gdprConsent = gdpr }
        if let usPrivacy = usPrivacy { self.usPrivacy = usPrivacy }
    }

    /// Provide the signed-in user's email for advanced (Meta-style) matching.
    /// The plaintext never leaves the device: it is trimmed, lowercased and
    /// SHA-256 hashed, and only the 64-char hex digest is sent as `em`. Pass
    /// `nil` or `""` to clear.
    public static func setEmail(_ email: String?) {
        shared.setEmail(email)
    }

    public func setEmail(_ email: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let email = email else { self.emailHash = nil; return }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.emailHash = normalized.isEmpty ? nil : Adviverse.sha256Hex(normalized)
    }

    /// Pre-set the already-hashed email (64-char lowercase hex SHA-256) when the
    /// host app prefers to hash itself. Invalid hashes are ignored.
    public func setEmailHash(_ hash: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let hash = hash, Adviverse.isValidEmailHash(hash) else { self.emailHash = nil; return }
        self.emailHash = hash
    }

    // MARK: Loading — completion API

    /// Request an ad. `placement` overrides the configured default tag for this
    /// call (use it when one app has several ad slots). Completion is delivered
    /// on the main queue.
    public static func loadAd(placement: String? = nil,
                              size: AdviverseAdSize,
                              format: AdviverseFormat = .banner,
                              completion: @escaping (Result<AdviverseAd, AdviverseError>) -> Void) {
        shared.loadAd(placement: placement, size: size, format: format, completion: completion)
    }

    public func loadAd(placement: String? = nil,
                       size: AdviverseAdSize,
                       format: AdviverseFormat = .banner,
                       completion: @escaping (Result<AdviverseAd, AdviverseError>) -> Void) {
        let tag: String
        let base: URL
        do {
            (tag, base) = try resolveRequestTarget(placement: placement)
        } catch let e as AdviverseError {
            return deliver(.failure(e), to: completion)
        } catch {
            return deliver(.failure(.network(error)), to: completion)
        }

        guard let url = buildAdRequestURL(tag: tag, base: base, size: size, format: format) else {
            return deliver(.failure(.invalidResponse), to: completion)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                return self.deliver(.failure(.network(error)), to: completion)
            }
            guard let http = response as? HTTPURLResponse else {
                return self.deliver(.failure(.invalidResponse), to: completion)
            }
            if http.statusCode == 204 {
                return self.deliver(.failure(.noFill), to: completion)
            }
            guard (200..<300).contains(http.statusCode) else {
                return self.deliver(.failure(.badStatus(http.statusCode)), to: completion)
            }
            guard let data = data, !data.isEmpty else {
                return self.deliver(.failure(.invalidResponse), to: completion)
            }
            do {
                var ad = try JSONDecoder().decode(AdviverseAd.self, from: data)
                ad.baseURL = base
                self.deliver(.success(ad), to: completion)
            } catch {
                self.deliver(.failure(.decoding(error)), to: completion)
            }
        }
        task.resume()
    }

    // MARK: Loading — async/await API

    /// async/await variant of `loadAd`. Throws an `AdviverseError` (including
    /// `.noFill` on a 204).
    @available(iOS 13.0, *)
    public static func loadAd(placement: String? = nil,
                              size: AdviverseAdSize,
                              format: AdviverseFormat = .banner) async throws -> AdviverseAd {
        try await shared.loadAd(placement: placement, size: size, format: format)
    }

    @available(iOS 13.0, *)
    public func loadAd(placement: String? = nil,
                       size: AdviverseAdSize,
                       format: AdviverseFormat = .banner) async throws -> AdviverseAd {
        try await withCheckedThrowingContinuation { continuation in
            self.loadAd(placement: placement, size: size, format: format) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: Request building

    private func resolveRequestTarget(placement: String?) throws -> (tag: String, base: URL) {
        lock.lock(); defer { lock.unlock() }
        let tag = (placement?.isEmpty == false ? placement : configuredTag) ?? ""
        if tag.isEmpty {
            // Distinguish "never configured" from "configured but no tag passed".
            throw configuredTag == nil ? AdviverseError.notConfigured : AdviverseError.missingTag
        }
        return (tag, baseURL)
    }

    /// Build the `/mobile/ad` URL, mirroring the params the engine reads. Empty
    /// values are omitted so we never send blank keys.
    private func buildAdRequestURL(tag: String,
                                   base: URL,
                                   size: AdviverseAdSize,
                                   format: AdviverseFormat) -> URL? {
        guard var comps = URLComponents(url: base.appendingPathComponent("mobile/ad"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        let identity = currentIdentity()
        let signals = deviceSignals()

        var items: [URLQueryItem] = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "format", value: format.rawValue),
            URLQueryItem(name: "client", value: Adviverse.clientName),
            URLQueryItem(name: "v", value: Adviverse.version)
        ]
        // Identity: always send the stable first-party uid; send the ifa only
        // when ATT permits, and always send lmt so the server knows the state.
        items.append(URLQueryItem(name: "uid", value: identity.uid))
        items.append(URLQueryItem(name: "lmt", value: identity.limitAdTracking ? "1" : "0"))
        if let ifa = identity.ifa { items.append(URLQueryItem(name: "ifa", value: ifa)) }

        // Size signals.
        if size.width > 0 { items.append(URLQueryItem(name: "w", value: String(size.width))) }
        if size.height > 0 { items.append(URLQueryItem(name: "h", value: String(size.height))) }

        // Device / app signals.
        appendIfNotEmpty(&items, "bundle", signals.bundle)
        appendIfNotEmpty(&items, "appname", signals.appName)
        appendIfNotEmpty(&items, "make", signals.make)
        appendIfNotEmpty(&items, "model", signals.model)
        appendIfNotEmpty(&items, "osv", signals.osVersion)

        // Consent + advanced matching (snapshot under lock).
        lock.lock()
        let gdpr = gdprConsent, usp = usPrivacy, em = emailHash
        lock.unlock()
        appendIfNotEmpty(&items, "gdpr_consent", gdpr)
        appendIfNotEmpty(&items, "us_privacy", usp)
        appendIfNotEmpty(&items, "em", em)

        comps.queryItems = items
        return comps.url
    }

    private func appendIfNotEmpty(_ items: inout [URLQueryItem], _ name: String, _ value: String?) {
        guard let value = value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    // MARK: Identity

    private struct Identity {
        let uid: String
        let ifa: String?
        let limitAdTracking: Bool
    }

    /// Resolve the device identity. The IDFA is used only when AppTracking is
    /// authorized; otherwise `lmt=1` and no `ifa` is sent (the engine then falls
    /// back to its cookieless IP+UA identity, but we still pass the stable
    /// first-party `uid` so frequency capping works within the app).
    private func currentIdentity() -> Identity {
        let uid = persistentUID()
        var ifa: String?
        var lmt = true

        #if canImport(AdSupport)
        if attAuthorized() {
            let raw = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            // The all-zero UUID means tracking is disabled at the OS level.
            if raw != "00000000-0000-0000-0000-000000000000" {
                ifa = raw
                lmt = false
            }
        }
        #endif
        return Identity(uid: uid, ifa: ifa, limitAdTracking: lmt)
    }

    /// True when the user has explicitly authorized tracking (iOS 14+). On older
    /// systems IDFA is available without ATT, so treat as authorized.
    private func attAuthorized() -> Bool {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        }
        #endif
        return true
    }

    /// A stable, app-scoped first-party id. Prefers `identifierForVendor`; falls
    /// back to a generated UUID persisted in `UserDefaults` so it survives across
    /// sessions even if IDFV is unavailable.
    private func persistentUID() -> String {
        if let stored = defaults.string(forKey: Adviverse.uidKey), !stored.isEmpty {
            return stored
        }
        var value: String?
        #if canImport(UIKit)
        value = UIDevice.current.identifierForVendor?.uuidString
        #endif
        let uid = "ios_" + (value ?? UUID().uuidString)
        defaults.set(uid, forKey: Adviverse.uidKey)
        return uid
    }

    // MARK: Device signals

    private struct DeviceSignals {
        let bundle: String?
        let appName: String?
        let make: String
        let model: String
        let osVersion: String
    }

    private func deviceSignals() -> DeviceSignals {
        let bundle = Bundle.main.bundleIdentifier
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        var osVersion = ""
        #if canImport(UIKit)
        osVersion = UIDevice.current.systemVersion
        #endif
        return DeviceSignals(
            bundle: bundle,
            appName: appName,
            make: "Apple", // lets the engine's UA-agnostic OS detection classify ios
            model: Adviverse.hardwareModelIdentifier(),
            osVersion: osVersion
        )
    }

    /// The hardware identifier (e.g. "iPhone15,2") from `uname`. More specific
    /// than `UIDevice.model` ("iPhone") for device-class targeting.
    static func hardwareModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id.isEmpty ? "iPhone" : id
    }

    // MARK: Beacons

    /// Fire-and-forget GET beacon (the sendBeacon equivalent). Used for the
    /// impression/click beacons. Failures are intentionally ignored — a missed
    /// beacon must never surface as a user-visible error.
    static func sendBeacon(_ url: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // The /click beacon 302-redirects to the advertiser; we don't want the
        // beacon task to actually follow it, so cap redirects via a short body.
        let task = URLSession.shared.dataTask(with: req)
        task.resume()
    }

    // MARK: Helpers

    /// Resolve a possibly-relative path (`/imp?rid=…`) against the base URL.
    static func absoluteURL(_ path: String, base: URL?) -> URL? {
        if let abs = URL(string: path), abs.scheme != nil { return abs }
        let base = base ?? defaultBaseURL
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    /// SHA-256 → lowercase hex (the `em` advanced-matching format).
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidEmailHash(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        return s.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }

    private func deliver(_ result: Result<AdviverseAd, AdviverseError>,
                         to completion: @escaping (Result<AdviverseAd, AdviverseError>) -> Void) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}
