import XCTest
@testable import AdviverseSDK

/// VAST parser / resolver tests. The network is stubbed via the resolver's
/// injectable fetcher, so these are deterministic and offline.
final class AdviverseVASTTests: XCTestCase {

    // MARK: Fixtures

    private func wrapper(next: String, imp: String, err: String = "https://w.example/err?c=[ERRORCODE]") -> String {
        """
        <VAST version="4.0"><Ad id="w"><Wrapper followAdditionalWrappers="true">
          <AdSystem>W</AdSystem>
          <VASTAdTagURI><![CDATA[\(next)]]></VASTAdTagURI>
          <Impression><![CDATA[\(imp)]]></Impression>
          <Error><![CDATA[\(err)]]></Error>
          <Creatives><Creative><Linear>
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://w.example/start]]></Tracking>
              <Tracking event="firstQuartile"><![CDATA[https://w.example/q1]]></Tracking>
            </TrackingEvents>
            <VideoClicks><ClickTracking><![CDATA[https://w.example/clk]]></ClickTracking></VideoClicks>
          </Linear></Creative></Creatives>
        </Wrapper></Ad></VAST>
        """
    }

    private let inline = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.0"><Ad id="i"><InLine>
      <AdSystem>I</AdSystem><AdTitle>T</AdTitle>
      <Impression><![CDATA[https://i.example/imp]]></Impression>
      <Error>https://i.example/err?c=[ERRORCODE]</Error>
      <Creatives><Creative><Linear skipoffset="00:00:05">
        <Duration>00:00:30.500</Duration>
        <TrackingEvents>
          <Tracking event="start">https://i.example/start</Tracking>
          <Tracking event="complete">https://i.example/done</Tracking>
        </TrackingEvents>
        <VideoClicks>
          <ClickThrough><![CDATA[https://advertiser.example/landing?a=1]]></ClickThrough>
          <ClickTracking>https://i.example/clk</ClickTracking>
        </VideoClicks>
        <MediaFiles>
          <MediaFile type="application/javascript" apiFramework="VPAID"><![CDATA[https://i.example/vpaid.js]]></MediaFile>
          <MediaFile type="video/webm" width="1280"><![CDATA[https://i.example/v.webm]]></MediaFile>
          <MediaFile type="video/mp4" width="1920"><![CDATA[https://i.example/1080.mp4]]></MediaFile>
          <MediaFile type="video/mp4" width="1280"><![CDATA[https://i.example/720.mp4]]></MediaFile>
          <MediaFile type="video/mp4" width="640"><![CDATA[https://i.example/360.mp4]]></MediaFile>
        </MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """

    /// Resolve `tag` against an in-memory URL → body map (prefix match, so
    /// expanded macros/cachebusters don't matter).
    private func resolve(_ tag: String, _ docs: [String: String]) -> (Result<AdviverseVASTResult, AdviverseVASTFailure>, [String]) {
        var fetched: [String] = []
        var out: Result<AdviverseVASTResult, AdviverseVASTFailure>?
        let fetch: AdviverseVAST.Fetcher = { url, done in
            fetched.append(url.absoluteString)
            let body = docs.first { url.absoluteString.hasPrefix($0.key) }?.value
            done(body.map { Data($0.utf8) })
        }
        AdviverseVAST.resolve(tag: tag, fetch: fetch) { out = $0 }
        return (out!, fetched)
    }

    // MARK: Tests

    func testInlinePicksMp4AndCollectsBeacons() throws {
        let (r, _) = resolve("https://i.example/vast", ["https://i.example/vast": inline])
        let v = try r.get()
        XCTAssertEqual(v.mediaURL?.absoluteString, "https://i.example/720.mp4")
        XCTAssertEqual(v.mediaType, "video/mp4")
        XCTAssertEqual(v.clickThrough?.absoluteString, "https://advertiser.example/landing?a=1")
        XCTAssertEqual(v.impressions, ["https://i.example/imp"])
        XCTAssertEqual(v.clickTrackings, ["https://i.example/clk"])
        XCTAssertEqual(v.tracking["complete"], ["https://i.example/done"])
        XCTAssertEqual(v.skipOffset, 5)
        XCTAssertEqual(v.duration ?? 0, 30.5, accuracy: 0.001)
    }

    func testWrapperChainAccumulatesAcrossHops() throws {
        let docs = [
            "https://a.example/tag": wrapper(next: "https://b.example/tag?cb=[CACHEBUSTING]", imp: "https://a.example/imp"),
            "https://b.example/tag": wrapper(next: "https://i.example/vast", imp: "https://b.example/imp"),
            "https://i.example/vast": inline
        ]
        let (r, fetched) = resolve("https://a.example/tag", docs)
        let v = try r.get()
        XCTAssertEqual(fetched.count, 3)
        XCTAssertFalse(fetched[1].contains("[CACHEBUSTING]"), "macro must be expanded")
        XCTAssertEqual(v.impressions, ["https://a.example/imp", "https://b.example/imp", "https://i.example/imp"])
        XCTAssertEqual(v.tracking["start"], ["https://w.example/start", "https://w.example/start", "https://i.example/start"])
        XCTAssertEqual(v.clickTrackings.count, 3)
        XCTAssertEqual(v.errors.count, 3)
        XCTAssertEqual(v.mediaURL?.absoluteString, "https://i.example/720.mp4")
    }

    func testEmptyVASTIs303WithRootError() {
        let empty = #"<VAST version="3.0"><Error><![CDATA[https://e.example/noad?c=[ERRORCODE]]]></Error></VAST>"#
        let (r, _) = resolve("https://e.example/tag", ["https://e.example/tag": empty])
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.code, 303)
        XCTAssertEqual(f.partial.errors, ["https://e.example/noad?c=[ERRORCODE]"])
    }

    func testWrapperLoopStopsAt302() {
        // A wrapper that points at itself must stop after maxWrappers hops.
        let loop = wrapper(next: "https://l.example/tag", imp: "https://l.example/imp")
        let (r, fetched) = resolve("https://l.example/tag", ["https://l.example/tag": loop])
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.code, 302)
        XCTAssertEqual(fetched.count, AdviverseVAST.maxWrappers)
        XCTAssertEqual(f.partial.impressions.count, AdviverseVAST.maxWrappers)
    }

    func testNoPlayableMediaIs403() {
        let vpaidOnly = """
        <VAST version="3.0"><Ad><InLine><Creatives><Creative><Linear><MediaFiles>
          <MediaFile type="application/javascript" apiFramework="VPAID">https://x.example/v.js</MediaFile>
          <MediaFile type="video/mp4" apiFramework="VPAID">https://x.example/v.mp4</MediaFile>
        </MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let (r, _) = resolve("https://x.example/tag", ["https://x.example/tag": vpaidOnly])
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.code, 403)
    }

    func testNetworkFailureIs301AndMalformedIs100() {
        let (net, _) = resolve("https://down.example/tag", [:])
        guard case .failure(let f1) = net else { return XCTFail("expected failure") }
        XCTAssertEqual(f1.code, 301)
        let (bad, _) = resolve("https://bad.example/tag", ["https://bad.example/tag": "<VAST><Ad>"])
        guard case .failure(let f2) = bad else { return XCTFail("expected failure") }
        XCTAssertEqual(f2.code, 100)
    }

    func testPickMediaFallsBackToPlayableNonMp4() throws {
        let hls = """
        <VAST><Ad><InLine><Creatives><Creative><Linear><MediaFiles>
          <MediaFile type="video/webm">https://h.example/v.webm</MediaFile>
          <MediaFile type="application/x-mpegURL">https://h.example/v.m3u8</MediaFile>
        </MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let root = try XCTUnwrap(VASTXML.parse(Data(hls.utf8)))
        let ad = try XCTUnwrap(root.first("Ad"))
        XCTAssertEqual(AdviverseVAST.pickMedia(ad)?.url.absoluteString, "https://h.example/v.m3u8")
    }

    func testOffsetsAndMacros() {
        XCTAssertEqual(AdviverseVAST.parseOffset("25%", duration: 20), 5)
        XCTAssertNil(AdviverseVAST.parseOffset("25%", duration: nil))
        XCTAssertEqual(AdviverseVAST.parseTime("01:02:03"), 3723)
        let e = AdviverseVAST.expandMacros("https://x/e?c=[ERRORCODE]&cb=[CACHEBUSTING]&t=[TIMESTAMP]", errorCode: 405)
        XCTAssertTrue(e.hasPrefix("https://x/e?c=405&cb="))
        XCTAssertFalse(e.contains("["))
        XCTAssertNotNil(AdviverseVAST.makeURL("https://x/p?a=[UNKNOWN]|b c"))
    }
}
