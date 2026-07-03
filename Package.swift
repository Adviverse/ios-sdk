// swift-tools-version:5.7
import PackageDescription

// AdviverseSDK — native iOS ad SDK for the Adviverse ad network.
//
// Zero external dependencies: networking is plain URLSession, hashing is
// CryptoKit, the optional banner view is UIKit. The package targets iOS only
// because identity (IDFA / identifierForVendor / ATT) and the drop-in
// `AdviverseAdView` rely on UIKit + AdSupport + AppTrackingTransparency.
let package = Package(
    name: "AdviverseSDK",
    platforms: [
        .iOS(.v13) // CryptoKit + AppTrackingTransparency baseline
    ],
    products: [
        .library(name: "AdviverseSDK", targets: ["AdviverseSDK"])
    ],
    targets: [
        .target(
            name: "AdviverseSDK",
            path: "Sources/AdviverseSDK",
            // Apple-required privacy manifest, shipped in the SDK's resource
            // bundle so apps that embed AdviverseSDK inherit its declarations.
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
