// WiFiProvisioningTests.swift — 0x07/0x07、0x07/0x0E 回复解析、读取状态机、日志打码。

import XCTest
#if canImport(PocketStudio)
@testable import PocketStudio
#else
@testable import PocketStudioCore
#endif

nonisolated final class WiFiProvisioningTests: XCTestCase {
    private func packed(_ text: String, status: UInt8 = 0) -> Bytes {
        let body = Array(text.utf8)
        return [status, UInt8(body.count)] + body
    }

    func testParseSSIDAndPassword() {
        let ssid = "OsmoPocket3-D6B1"
        XCTAssertEqual(WiFiProvisioning.parseReply(packed(ssid), query: .ssid), .value(ssid))
        let password = "abcd1234"
        XCTAssertEqual(WiFiProvisioning.parseReply(packed(password), query: .password), .value(password))
    }

    func testParseNotReadyAndShortReject() {
        XCTAssertEqual(WiFiProvisioning.parseReply([0xE4], query: .ssid), .notReady(0xE4))
        XCTAssertEqual(WiFiProvisioning.parseReply([0xE4, 0x00], query: .password), .notReady(0xE4))
        XCTAssertEqual(WiFiProvisioning.parseReply([0x01], query: .ssid), .rejected(0x01))
        XCTAssertEqual(WiFiProvisioning.parseReply([0xD8, 0x00], query: .password), .rejected(0xD8))
    }

    func testParseUnreadableMeansEncryptedOrUnknown() {
        XCTAssertEqual(WiFiProvisioning.parseReply([], query: .ssid), .unreadable)
        XCTAssertEqual(WiFiProvisioning.parseReply([0x00], query: .ssid), .unreadable)
        XCTAssertEqual(WiFiProvisioning.parseReply([0x00, 0x03, 0x41, 0x42], query: .ssid), .unreadable) // 长度不符
        XCTAssertEqual(WiFiProvisioning.parseReply([0x00, 0x02, 0x41, 0x42, 0x43], query: .ssid), .unreadable) // 多一字节
        XCTAssertEqual(WiFiProvisioning.parseReply([0x00, 0x02, 0xFF, 0xFF], query: .password), .unreadable) // 非法 UTF-8
        XCTAssertEqual(WiFiProvisioning.parseReply(packed("ab\ncd"), query: .password), .unreadable) // 控制字符
        XCTAssertEqual(WiFiProvisioning.parseReply([0x00, 0x00], query: .ssid), .unreadable)
        let blob = Bytes([0x11]) + Bytes(repeating: 0x9A, count: 16)
        XCTAssertEqual(WiFiProvisioning.parseReply(blob, query: .password), .unreadable)
        XCTAssertNil(WiFiProvisioning.plausibleSSID("DJI 设备"))
        XCTAssertNil(WiFiProvisioning.plausibleSSID("   "))
        XCTAssertEqual(WiFiProvisioning.plausibleSSID(" OsmoPocket4-AB12 "), "OsmoPocket4-AB12")
    }

    func testGetMessagesAreEmptyPayloadRequests() throws {
        let ssid = WiFiProvisioning.message(id: 0x0007, query: .ssid)
        let password = WiFiProvisioning.message(id: 0x0008, query: .password)
        XCTAssertEqual(ssid.payload, [])
        XCTAssertEqual(password.payload, [])
        XCTAssertEqual(ssid.target, 0x0702)
        let sb = DJIBLE.build(ssid)
        let pb = DJIBLE.build(password)
        XCTAssertEqual(Array(sb[8 ..< 11]), [0x40, 0x07, 0x07])
        XCTAssertEqual(Array(pb[8 ..< 11]), [0x40, 0x07, 0x0E])
        XCTAssertEqual(try DJIBLE.parse(sb), ssid)
        XCTAssertEqual(try DJIBLE.parse(pb), password)
    }

    func testPairingConfirmationAck() throws {
        let incoming = DJIBLEMessage(target: 0x0207, id: 0x1234, type: 0x460740, payload: [0x00, 0x02])
        XCTAssertTrue(WiFiProvisioning.isPairingConfirmation(incoming))
        XCTAssertFalse(WiFiProvisioning.isPairingConfirmation(WiFiProvisioning.message(id: 1, query: .ssid)))
        let ack = WiFiProvisioning.pairingConfirmationAck(for: incoming)
        XCTAssertEqual(ack.id, 0x1234)
        XCTAssertEqual(ack.payload, [0x00])
        XCTAssertEqual(Array(DJIBLE.build(ack)[8 ..< 11]), [0xC0, 0x07, 0x46])
        XCTAssertEqual(try DJIBLE.parse(DJIBLE.build(ack)).type, ack.type)
    }

    func testFetchHappyPathSpacesWrites() {
        var f = WiFiCredentialFetcher()
        var action = f.start(advertisedName: "OsmoPocket3-D6B1", now: 0)
        XCTAssertEqual(action, .wait(1.5))
        action = f.advance(now: 1.5)
        XCTAssertEqual(action, .send(.ssid, id: 0x8100))
        action = f.receive(query: .ssid, payload: packed("OsmoPocket3-D6B1"), now: 1.6)
        guard case let .wait(gap) = action else { return XCTFail("expected write spacing, got \(action)") }
        XCTAssertEqual(gap, 0.1, accuracy: 0.001) // 距上次写不足 200ms
        action = f.advance(now: 1.7)
        XCTAssertEqual(action, .send(.password, id: 0x8101))
        action = f.receive(query: .password, payload: packed("abcd1234"), now: 2.0)
        XCTAssertEqual(action, .success(WiFiCredentials(ssid: "OsmoPocket3-D6B1", password: "abcd1234", ssidFromAdvertisement: false)))
    }

    func testSSIDNotReadyUsesAdvertisedNameThenPassword() {
        var f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: "OsmoPocket4-AB12", now: 0)
        var action = f.advance(now: 1.5)
        XCTAssertEqual(action, .send(.ssid, id: 0x8100))
        action = f.receive(query: .ssid, payload: [0xE4], now: 2.0)
        XCTAssertEqual(action, .send(.password, id: 0x8101))
        action = f.receive(query: .password, payload: packed("pw-ok-99"), now: 3)
        XCTAssertEqual(action, .success(WiFiCredentials(ssid: "OsmoPocket4-AB12", password: "pw-ok-99", ssidFromAdvertisement: true)))
    }

    func testSSIDRetriesThenGivesUpWithoutName() {
        var f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: "DJI 设备", now: 0)
        var now: TimeInterval = 1.5
        var sends = 0
        var action = f.advance(now: now)
        while case let .send(query, _) = action {
            XCTAssertEqual(query, .ssid)
            sends += 1
            now += 0.4
            action = f.receive(query: .ssid, payload: [0xE4], now: now)
            if case let .wait(dt) = action {
                now += dt
                action = f.advance(now: now)
            }
        }
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(action, .failure(.ssidUnavailable))
    }

    func testPasswordRetriesThreeTimes() {
        var f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: nil, now: 0)
        var action = f.advance(now: 1.5)
        action = f.receive(query: .ssid, payload: packed("OsmoPocket3-D6B1"), now: 2)
        var sends = 0
        var now: TimeInterval = 2
        while case .send = action {
            sends += 1
            now += 0.5
            action = f.receive(query: .password, payload: [0xE4], now: now)
            if case let .wait(dt) = action {
                now += dt
                action = f.advance(now: now)
            }
        }
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(action, .failure(.passwordUnavailable))
    }

    func testUnreadableReplyStopsImmediately() {
        var f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: "OsmoPocket3-D6B1", now: 0)
        var action = f.advance(now: 1.5)
        action = f.receive(query: .ssid, payload: [0x00, 0x02, 0xFF, 0xFF], now: 2)
        XCTAssertEqual(action, .failure(.encrypted))

        f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: nil, now: 0)
        action = f.advance(now: 1.5)
        action = f.receive(query: .ssid, payload: packed("OsmoPocket3-D6B1"), now: 2)
        if case .wait = action { action = f.advance(now: 2.2) }
        action = f.receive(query: .password, payload: Bytes(repeating: 0xAB, count: 20), now: 3)
        XCTAssertEqual(action, .failure(.encrypted))
    }

    func testPollWindowStopsFurtherSends() {
        var f = WiFiCredentialFetcher(config: WiFiCredentialFetcher.Config(initialDelay: 1, retryGap: 3, pollWindow: 5, maxAttempts: 3))
        _ = f.start(advertisedName: nil, now: 0)
        var action = f.advance(now: 1)
        XCTAssertEqual(action, .send(.ssid, id: 0x8100))
        action = f.timedOut(query: .ssid, now: 4)
        XCTAssertEqual(action, .failure(.timedOut)) // 下次要等到 7s，超出 5s 窗口
    }

    func testTimeoutRetriesPasswordInsideWindow() {
        var f = WiFiCredentialFetcher()
        _ = f.start(advertisedName: "OsmoPocket3-D6B1", now: 10)
        var action = f.advance(now: 11.5)
        action = f.receive(query: .ssid, payload: [0xE4], now: 12)
        XCTAssertEqual(action, .send(.password, id: 0x8101))
        action = f.timedOut(query: .password, now: 15)
        XCTAssertEqual(action, .wait(1))
        action = f.advance(now: 16)
        XCTAssertEqual(action, .send(.password, id: 0x8102))
    }

    func testPlannerManualOverridesOnlyWhenAutoOff() {
        XCTAssertEqual(
            WiFiCredentialPlanner.plan(autoFetch: false, manualSSID: "Manual-1", manualPassword: "secret99",
                                      cachedSSID: "Cached", cachedPassword: "cached-pw", advertisedName: "Adv"),
            .manual(ssid: "Manual-1", password: "secret99"))
        XCTAssertEqual(
            WiFiCredentialPlanner.plan(autoFetch: false, manualSSID: "", manualPassword: "",
                                      cachedSSID: nil, cachedPassword: nil, advertisedName: nil),
            .needsManualEntry("已关闭自动获取 Wi-Fi，且未填写名称和密码"))
        XCTAssertEqual(
            WiFiCredentialPlanner.plan(autoFetch: true, manualSSID: "Manual-1", manualPassword: "secret99",
                                      cachedSSID: nil, cachedPassword: nil, advertisedName: "OsmoPocket3-D6B1"),
            .fetch)
        XCTAssertEqual(
            WiFiCredentialPlanner.plan(autoFetch: true, manualSSID: "", manualPassword: "",
                                      cachedSSID: "OsmoPocket3-D6B1", cachedPassword: "cached-pw",
                                      advertisedName: "OsmoPocket3-D6B1"),
            .cached(ssid: "OsmoPocket3-D6B1", password: "cached-pw"))
        XCTAssertEqual(
            WiFiCredentialPlanner.plan(autoFetch: true, manualSSID: "", manualPassword: "",
                                      cachedSSID: "Old-SSID", cachedPassword: "cached-pw",
                                      advertisedName: "OsmoPocket3-D6B1"),
            .fetch)
    }

    func testScanRetryBudget() {
        var scan = WiFiScanRetry()
        XCTAssertEqual(scan.record(.notFound), .retryAfter(5))
        scan.elapsed = 87
        XCTAssertEqual(scan.record(.notFound), .retryAfter(3))
        scan.elapsed = 90
        XCTAssertEqual(scan.record(.notFound), .stop)

        var assoc = WiFiScanRetry()
        XCTAssertEqual(assoc.record(.associate), .retryAfter(5))
        XCTAssertEqual(assoc.record(.associate), .retryAfter(5))
        XCTAssertEqual(assoc.record(.associate), .stop)
        XCTAssertEqual(assoc.associateFailures, 3)
        XCTAssertEqual(WiFiScanRetry.deadline, 90)
        XCTAssertEqual(WiFiScanRetry.addressWait, 15)
    }

    func testMaskPasswordInTextAndHex() {
        let password = "Secret99"
        let payload = packed(password)
        let dump = WiFiLogMask.hexDump(payload, query: .password)
        XCTAssertEqual(dump, "00 08 •••• (10 bytes)")
        XCTAssertFalse(dump.lowercased().contains(Array(password.utf8).hexString()))
        let ssidPayload = packed("OsmoPocket3-D6B1")
        XCTAssertEqual(WiFiLogMask.hexDump(ssidPayload, query: .ssid), ssidPayload.hexString(separator: " "))

        let line = "pwd=Secret99 hex=\(Array(password.utf8).hexString(separator: " ")) compact=\(Array(password.utf8).hexString())"
        let redacted = WiFiLogMask.redact(password, in: line)
        XCTAssertFalse(redacted.contains(password))
        XCTAssertFalse(redacted.lowercased().contains(Array(password.utf8).hexString()))
        XCTAssertFalse(redacted.lowercased().contains(Array(password.utf8).hexString(separator: " ")))
        XCTAssertTrue(redacted.contains("••••"))
        XCTAssertEqual(WiFiLogMask.redact("ab", in: "ab"), "ab")
    }

    func testCredentialBlobRoundTrip() {
        let raw = WiFiCredentialBlob.encode(ssid: "OsmoPocket3-D6B1", password: "p\"w\n99")
        XCTAssertFalse(raw.contains("\n"))
        let decoded = WiFiCredentialBlob.decode(raw)
        XCTAssertEqual(decoded?.ssid, "OsmoPocket3-D6B1")
        XCTAssertEqual(decoded?.password, "p\"w\n99")
        XCTAssertNil(WiFiCredentialBlob.decode("{"))
    }
}
