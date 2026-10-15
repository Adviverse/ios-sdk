//
//  AdviverseVAST.swift
//  AdviverseSDK
//
//  Third-party VAST tag resolver. A video creative may carry a third-party
//  VAST tag (`vast_tag_url`) instead of a hosted asset (`asset_url` empty). The
//  loader resolves it BEFORE reporting success: fetch the tag, follow the
//  Wrapper chain (≤5 hops), pick a playable MediaFile (video/mp4 first, then
//  anything AVPlayer plays; VPAID / JavaScript units are skipped) and collect
//  every third-party beacon along the chain (Impression / Error / Tracking /
//  ClickTracking) plus the final ClickThrough, skipoffset and Duration.
//
//  Mirrors the web SDK's sdk_vast.js semantics. Dependency-free: Foundation's
//  XMLParser + URLSession only.
//

import Foundation

/// The resolved third-party VAST chain for an ad. Every URL list is the union
/// across all Wrapper hops plus the final InLine, in document order.
public struct AdviverseVASTResult {
    /// The chosen progressive MediaFile.
    public internal(set) var mediaURL: URL?
    public internal(set) var mediaType: String = ""
    /// The InLine `<ClickThrough>` (the advertiser destination).
    public internal(set) var clickThrough: URL?
    public internal(set) var impressions: [String] = []
    public internal(set) var errors: [String] = []
    public internal(set) var clickTrackings: [String] = []
    /// Linear `<Tracking event="…">` URLs keyed by event name.
    public internal(set) var tracking: [String: [String]] = [:]
    /// Linear `skipoffset` in seconds; nil = not skippable.
    public internal(set) var skipOffset: TimeInterval?
    /// InLine `<Duration>` in seconds, when present.
    public internal(set) var duration: TimeInterval?

    public init() {}
}

/// A failed resolution: a VAST error code (100 XML, 301 timeout/network,
/// 302 wrapper limit, 303 empty VAST, 403 no supported media) plus whatever
/// beacons were collected before the failure (their `<Error>` URLs must fire).
public struct AdviverseVASTFailure: Error {
    public let code: Int
    public let partial: AdviverseVASTResult
}

enum AdviverseVAST {

    static let maxWrappers = 5
    static let timeout: TimeInterval = 8

    /// Fetches a URL's body (nil on any transport / non-2xx failure). Injectable
    /// so the resolver is unit-testable without the network.
    typealias Fetcher = (URL, @escaping (Data?) -> Void) -> Void

    // MARK: Resolution

    /// Resolve `tag` through its Wrapper chain. `completion` is called exactly
    /// once, on an arbitrary queue.
    static func resolve(tag: String,
                        fetch: @escaping Fetcher = defaultFetch,
                        completion: @escaping (Result<AdviverseVASTResult, AdviverseVASTFailure>) -> Void) {
        var acc = AdviverseVASTResult()
        func fail(_ code: Int) { completion(.failure(AdviverseVASTFailure(code: code, partial: acc))) }
        func step(_ urlString: String, depth: Int) {
            if depth > maxWrappers { return fail(302) }
            guard let url = makeURL(expandMacros(urlString)) else { return fail(301) }
            fetch(url) { data in
                guard let data = data, !data.isEmpty else { return fail(301) }
                guard let root = VASTXML.parse(data) else { return fail(100) }
                switch apply(root, to: &acc) {
                case .next(let u): step(u, depth: depth + 1)
                case .done: completion(.success(acc))
                case .failed(let code): fail(code)
                }
            }
        }
        step(tag, depth: 1)
    }

    enum Step: Equatable { case next(String), done, failed(Int) }

    /// Apply one parsed VAST document to the accumulated chain result.
    static func apply(_ root: VASTNode, to acc: inout AdviverseVASTResult) -> Step {
        guard let ad = root.first("Ad") else {
            // No-ad response: its root-level <Error> is the one to report.
            let top = root.first("VAST") ?? root
            for e in top.children where e.name == "Error" && !e.text.isEmpty { acc.errors.append(e.text) }
            return .failed(303)
        }
        collect(ad, into: &acc)
        if ad.first("Wrapper") != nil, let next = ad.first("VASTAdTagURI")?.text, !next.isEmpty {
            return .next(next)
        }
        acc.clickThrough = ad.first("ClickThrough").flatMap { makeURL($0.text) }
        acc.duration = ad.first("Duration").flatMap { parseTime($0.text) }
        if let raw = ad.first("Linear")?.attrs["skipoffset"] {
            acc.skipOffset = parseOffset(raw, duration: acc.duration)
        }
        guard let media = pickMedia(ad) else { return .failed(403) }
        acc.mediaURL = media.url
        acc.mediaType = media.type
        return .done
    }

    static func collect(_ ad: VASTNode, into acc: inout AdviverseVASTResult) {
        for n in ad.all("Impression") where !n.text.isEmpty { acc.impressions.append(n.text) }
        for n in ad.all("Error") where !n.text.isEmpty { acc.errors.append(n.text) }
        for n in ad.all("ClickTracking") where !n.text.isEmpty { acc.clickTrackings.append(n.text) }
        for n in ad.all("Tracking") where !n.text.isEmpty {
            guard let ev = n.attrs["event"], !ev.isEmpty else { continue }
            acc.tracking[ev, default: []].append(n.text)
        }
    }

    // MARK: MediaFile selection

    /// Non-mp4 types AVPlayer plays natively, in preference order.
    static let playableTypes = ["video/quicktime", "video/x-m4v", "video/3gpp",
                                "application/x-mpegurl", "application/vnd.apple.mpegurl"]

    /// Choose a progressive, non-interactive MediaFile: video/mp4 first, then any
    /// other AVPlayer-playable type. Within a type, the widest rendition ≤1280px
    /// wins (mobile-friendly bitrate), else the narrowest.
    static func pickMedia(_ ad: VASTNode) -> (url: URL, type: String)? {
        let files: [(url: URL, type: String, width: Int)] = ad.all("MediaFile").compactMap { n in
            let type = (n.attrs["type"] ?? "").lowercased()
            let api = (n.attrs["apiFramework"] ?? "").lowercased()
            if api.contains("vpaid") || type.contains("javascript") || type.contains("shockwave") { return nil }
            let lower = n.text.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"),
                  let url = makeURL(n.text) else { return nil }
            return (url, type, Int(n.attrs["width"] ?? "") ?? 0)
        }
        for t in ["video/mp4"] + playableTypes {
            let same = files.filter { $0.type == t }
            if same.isEmpty { continue }
            let fit = same.filter { $0.width <= 1280 }.max { $0.width < $1.width }
            let best = fit ?? same.min { $0.width < $1.width }!
            return (best.url, best.type)
        }
        return nil
    }

    // MARK: Time parsing

    /// "HH:MM:SS" or "HH:MM:SS.mmm" → seconds.
    static func parseTime(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// skipoffset is a time ("00:00:05") or a percentage ("25%") of duration.
    static func parseOffset(_ s: String, duration: TimeInterval?) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") {
            guard let pct = Double(t.dropLast()), let d = duration else { return nil }
            return d * pct / 100
        }
        return parseTime(t)
    }

    // MARK: Macros + firing

    /// Fill the IAB macros a player is responsible for.
    static func expandMacros(_ u: String, errorCode: Int? = nil) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return u.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[CACHEBUSTING]", with: String(Int.random(in: 10_000_000...99_999_999)))
            .replacingOccurrences(of: "[TIMESTAMP]", with: ts)
            .replacingOccurrences(of: "[ERRORCODE]", with: errorCode.map(String.init) ?? "")
    }

    /// URL(string:) with a lenient fallback for unencoded characters (leftover
    /// macros, spaces, pipes) that third-party ad servers routinely emit.
    static func makeURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let u = URL(string: t), u.scheme != nil { return u }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        allowed.remove(charactersIn: "[]")
        guard let enc = t.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: enc), u.scheme != nil else { return nil }
        return u
    }

    /// Fire third-party GET beacons (VAST trackers expect GET).
    static func fire(_ urls: [String], errorCode: Int? = nil) {
        for u in urls {
            if let url = makeURL(expandMacros(u, errorCode: errorCode)) { Adviverse.sendBeacon(url) }
        }
    }

    static let defaultFetch: Fetcher = { url, done in
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            done(error == nil && ok ? data : nil)
        }.resume()
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }()

    // MARK: Loader integration

    /// Called by `Adviverse.loadAd` after decoding. A wrapper creative is resolved
    /// before success is reported; on failure the chain's `<Error>` URLs and our
    /// `ev=error` beacon fire and the load reports `.noFill`.
    static func attach(to ad: AdviverseAd, completion: @escaping (Result<AdviverseAd, AdviverseError>) -> Void) {
        guard ad.creative.needsVASTResolution, let tag = ad.creative.vastTagURL else {
            return completion(.success(ad))
        }
        resolve(tag: tag) { result in
            switch result {
            case .success(let vast):
                var resolved = ad
                resolved.vast = vast
                completion(.success(resolved))
            case .failure(let f):
                fire(f.partial.errors, errorCode: f.code)
                ad.reportVideoError(f.code, includeChain: false)
                completion(.failure(.noFill))
            }
        }
    }
}

// MARK: - Video helpers on the ad model

/// Per-ad dedup of video lifecycle events (each fires at most once).
final class AdviverseVideoEventState {
    private let lock = NSLock()
    private var fired = Set<String>()
    func mark(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fired.insert(event).inserted
    }
}

extension AdviverseCreative {
    /// True for a third-party VAST "wrapper creative": no hosted asset, a tag.
    var needsVASTResolution: Bool {
        (assetURL ?? "").isEmpty && !(vastTagURL ?? "").isEmpty
    }
}

public extension AdviverseAd {

    /// The playable video URL: the hosted `asset_url` for a video creative, else
    /// the MediaFile resolved from its third-party VAST tag.
    var videoURL: URL? {
        if let a = creative.assetURL, !a.isEmpty, creative.type == "video" {
            return Adviverse.absoluteURL(a, base: baseURL)
        }
        return vast?.mediaURL
    }

    /// True when this ad should be presented as video.
    var isVideo: Bool { videoURL != nil }

    /// Seconds after which a Skip control may appear (VAST skipoffset, else the
    /// creative's `skip_offset_sec`); nil = not skippable.
    var skipOffset: TimeInterval? {
        if let s = vast?.skipOffset, s > 0 { return s }
        if let s = creative.skipOffsetSec, s > 0 { return TimeInterval(s) }
        return nil
    }

    /// Fire a video lifecycle event (start, firstQuartile, midpoint,
    /// thirdQuartile, complete, skip, mute, …) at most once: our tracking-only
    /// `imp_url&ev=<event>` plus the third-party VAST trackers for it.
    func fireVideoEvent(_ event: String) {
        guard videoState.mark(event) else { return }
        if let imp = impressionURL, let url = URL(string: imp.absoluteString + "&ev=" + event) {
            Adviverse.sendBeacon(url)
        }
        if let v = vast { AdviverseVAST.fire(v.tracking[event] ?? []) }
    }

    /// Report a VAST error (e.g. 405 media playback failure): the chain's
    /// `<Error>` URLs with [ERRORCODE] filled, plus our tracking-only beacon.
    func reportVideoError(_ code: Int) { reportVideoError(code, includeChain: true) }
}

extension AdviverseAd {
    func reportVideoError(_ code: Int, includeChain: Bool) {
        guard videoState.mark("error") else { return }
        if includeChain, let v = vast { AdviverseVAST.fire(v.errors, errorCode: code) }
        if let imp = impressionURL, let url = URL(string: imp.absoluteString + "&ev=error&code=\(code)") {
            Adviverse.sendBeacon(url)
        }
    }
}

// MARK: - Minimal XML tree (Foundation XMLParser)

/// A parsed XML element: name, attributes, trimmed text (CDATA included) and
/// children. Only what VAST resolution needs.
final class VASTNode {
    let name: String
    let attrs: [String: String]
    var text = ""
    var children: [VASTNode] = []

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    /// All descendants named `name`, in document order.
    func all(_ name: String) -> [VASTNode] {
        var out: [VASTNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.all(name))
        }
        return out
    }

    /// First descendant named `name` (document order).
    func first(_ name: String) -> VASTNode? {
        for c in children {
            if c.name == name { return c }
            if let hit = c.first(name) { return hit }
        }
        return nil
    }
}

final class VASTXML: NSObject, XMLParserDelegate {
    private let root = VASTNode(name: "#document", attrs: [:])
    private var stack: [VASTNode] = []
    private var buffers: [String] = []

    /// Parse `data` into a tree rooted at a synthetic document node; nil on
    /// malformed XML.
    static func parse(_ data: Data) -> VASTNode? {
        let p = XMLParser(data: data)
        let d = VASTXML()
        d.stack = [d.root]
        d.buffers = [""]
        p.delegate = d
        p.shouldResolveExternalEntities = false
        return p.parse() ? d.root : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = VASTNode(name: local, attrs: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
        buffers.append("")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !buffers.isEmpty { buffers[buffers.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if !buffers.isEmpty { buffers[buffers.count - 1] += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard stack.count > 1, let node = stack.popLast(), let buf = buffers.popLast() else { return }
        node.text = buf.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
