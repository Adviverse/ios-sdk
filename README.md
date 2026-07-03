# AdviverseSDK (iOS)

Native Swift ad SDK for the **Adviverse** ad network. Zero external
dependencies — networking is `URLSession`, hashing is `CryptoKit`, the optional
drop-in banner is `UIKit`. It talks to the engine's `/mobile/ad` endpoint and
mirrors that contract exactly (in-app signals in, standard ad JSON + SKAdNetwork
out, impression/click beacons).

- iOS 13+
- No third-party dependencies
- Async/await **and** completion-handler APIs

## Install (Swift Package Manager)

In Xcode: **File ▸ Add Packages…** and point at this package, or add it to your
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Adviverse/ios-sdk.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AdviverseSDK", package: "ios-sdk")
    ])
]
```

```swift
import AdviverseSDK
```

## Quick start

Configure once at launch with your placement tag (and an optional base URL for
staging / a custom edge domain):

```swift
// AppDelegate / App init
Adviverse.configure(tag: "ios-banner-home")
// Adviverse.configure(tag: "ios-banner-home", baseURL: URL(string: "https://staging.adviverse.com"))
```

### Drop-in banner (UIKit)

```swift
let banner = AdviverseAdView(size: .banner)        // 320×50
banner.delegate = self
view.addSubview(banner)
banner.load()                                       // uses the configured tag
```

The view loads the creative, fires the impression once it's actually on screen,
and on tap fires the click beacon and opens the advertiser landing page.

### Load an ad yourself

```swift
// async/await
let ad = try await Adviverse.loadAd(size: .mediumRectangle, format: .banner)
ad.fireImpression()
// … on tap:
ad.fireClick()
if let url = ad.landingURL { UIApplication.shared.open(url) }

// completion handler
Adviverse.loadAd(placement: "ios-rewarded-level-end", size: .fullScreen, format: .rewarded) { result in
    switch result {
    case .success(let ad):
        // render, then ad.fireImpression() / ad.fireClick()
        if let reward = ad.rewardURL { /* grant reward server-side after this S2S callback */ }
    case .failure(.noFill):
        break // expected: no ad this time (or version-gated)
    case .failure(let error):
        print("ad error:", error)
    }
}
```

`placement:` overrides the configured tag for a single call (use it when one app
has several ad slots). Sizes are forwarded as `w`/`h`; `.fullScreen` omits them.

## Consent (GDPR / CCPA)

Set the IAB TCF string and/or the US-privacy string; they're forwarded verbatim
as `gdpr_consent` and `us_privacy`. Set them before requesting ads (e.g. right
after your CMP resolves):

```swift
Adviverse.setConsent(gdpr: tcfConsentString, usPrivacy: "1YNN")
```

When tracking isn't permitted the SDK still serves contextual ads — it simply
omits the IDFA (see below).

## Identity & App Tracking Transparency

- The SDK always sends a stable first-party `uid` (derived from
  `identifierForVendor`, persisted in `UserDefaults`) so frequency capping works
  within your app.
- The **IDFA (`ifa`)** is sent **only** when the user has authorized tracking via
  ATT. Otherwise the SDK sends `lmt=1` and omits the IDFA, and the engine falls
  back to its cookieless identity.

To use the IDFA you must request authorization yourself and add the usage
description to `Info.plist`:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use your data to show you more relevant ads.</string>
```

```swift
import AppTrackingTransparency
ATTrackingManager.requestTrackingAuthorization { _ in
    // then load ads — the SDK reads the resulting status automatically
}
```

## Email advanced matching (`em`)

Provide the signed-in user's email for Meta-style advanced matching. The
plaintext **never leaves the device**: it's trimmed, lowercased, and SHA-256
hashed, and only the 64-char hex digest is sent as `em`.

```swift
Adviverse.setEmail("User@Example.com")   // → sha256("user@example.com")
Adviverse.setEmail(nil)                   // clear
// or, if you hash yourself:
Adviverse.shared.setEmailHash("<64-char lowercase hex sha256>")
```

## SKAdNetwork (iOS attribution)

When the server is configured with an SKAdNetwork id, an iOS ad response carries
an `skadn` block, surfaced as `ad.skAdNetwork`:

```swift
if let skan = ad.skAdNetwork {
    if skan.isSigned {
        // Production-signed: safe to drive StoreKit attribution.
        // e.g. SKAdNetwork.updateConversionValue(_:) on a qualifying event,
        // or pass skan.attributionDictionary to your StoreKit flow.
    } else {
        // signaturePlaceholder == true: NOT a valid Apple signature.
    }
}
```

> **Production signatures are server-side.** A placeholder signature
> (`signaturePlaceholder == true`) is for wiring up the integration only — it is
> not attributable. A valid Apple signature must be produced server-side by
> signing Apple's exact field ordering with the network's SKAdNetwork private
> key (`SKADNETWORK_PRIVATE_KEY` on the engine). Gate any StoreKit attribution
> call on `skan.isSigned`. You must also list the network's SKAdNetwork id under
> `SKAdNetworkItems` in your app's `Info.plist`.

## Rewarded video

For `format: .rewarded`, the response includes a signed server-to-server
`reward_url`. Grant the reward only after that callback is verified by your
backend (the signature proves the reward came from a legitimately-served ad) —
never client-side.

## Public API surface

| Symbol | Purpose |
| --- | --- |
| `Adviverse.configure(tag:baseURL:)` | One-time setup |
| `Adviverse.setConsent(gdpr:usPrivacy:)` | GDPR/CCPA passthrough |
| `Adviverse.setEmail(_:)` / `setEmailHash(_:)` | `em` advanced matching |
| `Adviverse.loadAd(placement:size:format:completion:)` | Load (completion) |
| `Adviverse.loadAd(placement:size:format:) async throws` | Load (async) |
| `AdviverseAd` | Decoded ad: `fireImpression()`, `fireClick()`, `landingURL`, `skAdNetwork`, `rewardURL` |
| `AdviverseCreative` | Creative fields (`bannerImageURL`, title, cta, …) |
| `AdviverseSKAdNetwork` | `isSigned`, `attributionDictionary`, raw fields |
| `AdviverseAdView` | Drop-in UIKit banner + `AdviverseAdViewDelegate` |
| `AdviverseAdSize` / `AdviverseFormat` | Request size & format |
| `AdviverseError` | `.noFill`, `.badStatus`, `.decoding`, … |
