import XCTest
#if canImport(PocketStudio)
@testable import PocketStudio
#else
@testable import PocketStudioCore
#endif

/// 轴映射 / 方向 / 可靠停止 / 看门狗（纯逻辑）
nonisolated final class GimbalControlTests: XCTestCase {
    private func fields(_ p: Bytes) -> (Int, Int, Int) { (Int(p.le16(0)), Int(p.le16(2)), Int(p.le16(4))) }

    func testDefaultAxisOrderPutsPitchFirstYawThird() {
        var g = GimbalSpeedController()
        XCTAssertEqual(g.axisOrder, .pitchRollYaw)
        // 右转（yaw +1）→ 第 3 字段满速，第 1 字段居中
        var f = fields(g.set(yaw: 1, pitch: 0, now: 0))
        XCTAssertEqual(f.0, 1024); XCTAssertEqual(f.1, 0); XCTAssertEqual(f.2, 2048)
        // 上仰（pitch +1）→ 第 1 字段满速
        f = fields(g.set(yaw: 0, pitch: 1, now: 0))
        XCTAssertEqual(f.0, 2048); XCTAssertEqual(f.2, 1024)
        // 左 / 下 为负方向
        f = fields(g.set(yaw: -1, pitch: -1, now: 0))
        XCTAssertEqual(f.0, 0); XCTAssertEqual(f.2, 0)
        XCTAssertEqual(g.payload().suffix(4), [0x00, 0x80, 0x42, 0x00])
    }

    func testLegacyOrderAndInversion() {
        var g = GimbalSpeedController()
        g.axisOrder = .yawRollPitch
        var f = fields(g.set(yaw: 1, pitch: 0, now: 0))
        XCTAssertEqual(f.0, 2048); XCTAssertEqual(f.2, 1024)
        g.axisOrder = .pitchRollYaw; g.invertYaw = true; g.invertPitch = true
        f = fields(g.set(yaw: 1, pitch: 0.5, now: 0))
        XCTAssertEqual(f.2, 0)              // yaw 反转
        XCTAssertEqual(f.0, 1024 - 512)     // pitch 反转
    }

    func testStopIsRepeatedAndNeverResendsOldSpeed() {
        var g = GimbalSpeedController()
        g.streaming = false
        g.set(yaw: 0.8, pitch: 0.4, now: 0)
        XCTAssertNotNil(g.tick(now: 0.03))                 // 运动中持续发送
        let first = fields(g.stop())
        XCTAssertEqual(first.0, 1024); XCTAssertEqual(first.2, 1024)
        var zeros = 1
        for i in 1 ... 20 {
            if let p = g.tick(now: 0.03 + Double(i) * 0.033) {
                let f = fields(p); XCTAssertEqual(f.0, 1024); XCTAssertEqual(f.2, 1024); zeros += 1
            }
        }
        XCTAssertEqual(zeros, g.stopRepeats, "停止共发送 stopRepeats 次零速，之后（非 streaming）不再发包")
    }

    func testStreamingAfterStopSendsOnlyZero() {
        var g = GimbalSpeedController()
        g.streaming = true
        g.set(yaw: 1, pitch: 1, now: 0)
        g.stop()
        for i in 1 ... 30 { let f = fields(g.tick(now: Double(i) * 0.033)!); XCTAssertEqual(f.0, 1024); XCTAssertEqual(f.2, 1024) }
    }

    func testIdleDoesNotFloodByDefault() {
        var g = GimbalSpeedController()
        XCTAssertFalse(g.streaming)
        g.set(yaw: 1, pitch: 0, now: 0); g.stop()
        var n = 0
        for i in 1 ... 60 where g.tick(now: Double(i) * 0.033) != nil { n += 1 }
        XCTAssertLessThanOrEqual(n, g.stopRepeats)
    }

    func testZeroInputIsAStop() {
        var g = GimbalSpeedController()
        g.set(yaw: 1, pitch: 0, now: 0)
        g.set(yaw: 0, pitch: 0, now: 0.01)
        XCTAssertFalse(g.isMoving)
        XCTAssertEqual(g.pendingStops, g.stopRepeats - 1)
    }

    func testWatchdogAutoZero() {
        var g = GimbalSpeedController()
        g.set(yaw: 1, pitch: 0, now: 0)
        XCTAssertEqual(fields(g.tick(now: 0.2)!).2, 2048)
        g.set(yaw: 1, pitch: 0, now: 0.25)                // 持续手势刷新
        XCTAssertEqual(fields(g.tick(now: 0.5)!).2, 2048) // 0.25s 后仍在动
        XCTAssertEqual(fields(g.tick(now: 0.6)!).2, 1024) // >0.3s 无输入 → 归零
        XCTAssertFalse(g.isMoving)
    }

    func testNudgeStopsAtDeadlineNotByWatchdog() {
        var g = GimbalSpeedController()
        g.nudge(yaw: 0, pitch: 1, duration: 0.5, now: 0)
        XCTAssertEqual(fields(g.tick(now: 0.4)!).0, 2048) // 超过看门狗阈值但仍在 nudge 时长内
        XCTAssertEqual(fields(g.tick(now: 0.51)!).0, 1024)
        XCTAssertFalse(g.isMoving)
    }
}

/// 14:17 日志：拖动时每个鼠标事件立即发包 + tick，峰值 84 包/s → 相机命令通道停止应答。
nonisolated final class GimbalRateLimitTests: XCTestCase {
    func testDragFloodIsCoalescedTo25Hz() {
        var t = 0.0
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.clock = { t }
        _ = core.makeHandshake(seed: 0)
        core.startVideo()
        core.noteGimbalAttitude()
        t = 5; core.tickGimbal()   // 就绪
        let start = core.gimbalTXCount
        // 2s：每 4ms 一个 mouseDragged（250 事件/s）+ 100ms 保活 + 40ms tick
        var nextTick = 5.0
        var i = 0
        while t < 7 {
            t += 0.004; i += 1
            core.setGimbalSpeed(yaw: sin(Double(i) / 30) * 0.8, pitch: 0.5)
            if t >= nextTick { core.tickGimbal(); nextTick += GimbalProtocol.sendInterval }
        }
        let n = core.gimbalTXCount - start
        XCTAssertLessThanOrEqual(n, 52, "2s 内云台包应 ≤ 25Hz，实际 \(n)")
        XCTAssertGreaterThanOrEqual(n, 40)
        // 松手：零速补发 stopRepeats 次，之后不再发
        core.stopGimbal()
        let before = core.gimbalTXCount
        for _ in 0 ..< 50 { t += 0.04; core.tickGimbal() }
        XCTAssertLessThanOrEqual(core.gimbalTXCount - before, core.gimbal.stopRepeats)
    }

    func testSpeedCommandsAreNotifyNotRequest() {
        var sent: [DUMLPacket] = []
        var t = 0.0
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.clock = { t }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        _ = core.makeHandshake(seed: 0)
        core.stopGimbal(); t = 1; core.tickGimbal()
        let g = sent.filter { $0.cmdSet == DUMLCmdSet.gimbal && $0.cmdID == GimbalProtocol.cmdControl }
        XCTAssertFalse(g.isEmpty)
        XCTAssertTrue(g.allSatisfy { $0.cmdType == DUMLCmdType.notify }, "摇杆包不应要求应答")
    }
}
