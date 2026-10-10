// StatusViewController.swift — 设备状态详情（电池 / 录制 / SD 卡 / 云台姿态 / 链路统计 / 原始负载）

import AppKit

@MainActor
final class StatusViewController: NSViewController {
    private let model = AppModel.shared
    private var values: [String: NSTextField] = [:]
    private var observer: NSObjectProtocol?

    private let sections: [(String, [(String, String)])] = [
        ("相机", [("conn", "连接"), ("mode", "拍摄模式"), ("rec", "相机录制"), ("recTime", "录制时长"), ("sd", "SD 卡")]),
        ("电池", [("bat", "电量"), ("mv", "电压"), ("bleBat", "蓝牙上报电量")]),
        ("云台姿态", [("yaw", "偏航 Yaw"), ("pitch", "俯仰 Pitch"), ("roll", "横滚 Roll"), ("gmode", "模式字节")]),
        ("视频", [("res", "分辨率"), ("fps", "帧率"), ("kbps", "码率"), ("frames", "已解码帧"), ("mb", "累计数据")]),
        ("链路", [("session", "Session"), ("rx", "UDP 收包"), ("tx", "UDP 发包"), ("duml", "DUML 包"), ("types", "收包类型分布")]),
        ("原始负载（逆向参考）", [("raw80", "Camera:0x80"), ("rawDC", "Camera:0xDC"), ("rawBat", "ESC:0x02")]),
    ]

    override func loadView() {
        let stack = UI.vstack([UI.title("设备状态")], spacing: 18)
        for (title, rows) in sections {
            let grid = NSGridView()
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = 8; grid.columnSpacing = 16
            for (key, name) in rows {
                let n = UI.label(name, size: 13, color: .secondaryLabelColor)
                let v = UI.label("—", size: 13, weight: .medium, mono: key.hasPrefix("raw") || key == "types")
                v.isSelectable = true
                v.lineBreakMode = .byCharWrapping
                v.maximumNumberOfLines = key.hasPrefix("raw") ? 4 : 1
                v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                values[key] = v
                grid.addRow(with: [n, v])
            }
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 120
            let card = CardView(UI.vstack([UI.headline(title), grid], spacing: 10))
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = UI.scrollingPage(stack)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func set(_ k: String, _ s: String) { values[k]?.stringValue = s }

    private func refresh() {
        guard view.window != nil else { return }
        let snap = model.snapshot, c = snap.camera, g = snap.gimbal, v = model.videoStats
        switch model.phase {
        case .idle: set("conn", "未连接")
        case .connecting: set("conn", "连接中…")
        case .connected: set("conn", "已连接")
        case let .failed(m): set("conn", "失败：\(m)")
        }
        set("mode", c.hasCameraStatus ? "\(c.modeName)（\(c.modeRaw ?? 0)）" : "—")
        set("rec", c.recording ? "录制中" : "未录制")
        set("recTime", "\(c.recordingTimeS) 秒")
        set("sd", c.hasStorageStatus ? (c.sdInserted ? "已插入" : "未插入") : "—")
        set("bat", c.batteryPercent >= 0 ? "\(c.batteryPercent)%" : "—")
        set("mv", c.batteryMilliVolt > 0 ? "\(c.batteryMilliVolt) mV" : "—")
        set("bleBat", model.bleBattery.map { "\($0)%" } ?? "—")
        set("yaw", g.valid ? String(format: "%.1f°", g.yaw) : "—")
        set("pitch", g.valid ? String(format: "%.1f°", g.pitch) : "—")
        set("roll", g.valid ? String(format: "%.1f°", g.roll) : "—")
        set("gmode", g.modeByte.map { String(format: "0x%02X", $0) } ?? "—")
        set("res", v.width > 0 ? "\(v.width) × \(v.height)" : "—")
        set("fps", "\(v.fps)")
        set("kbps", "\(v.kbps) kbps")
        set("frames", "\(v.frames)")
        set("mb", String(format: "%.1f MB", Double(v.bytes) / 1_048_576))
        set("session", String(format: "0x%04X", snap.sessionID))
        set("rx", "\(snap.stats.rxPackets) 包 / \(snap.stats.rxBytes / 1024) KB")
        set("tx", "\(snap.stats.txPackets) 包 / \(snap.stats.txBytes / 1024) KB")
        set("duml", "\(snap.stats.dumlPackets)")
        set("types", snap.stats.rxTypeCounts.sorted { $0.key < $1.key }.map { "\(DJIUDPType.names[$0.key] ?? "\($0.key)")=\($0.value)" }.joined(separator: " "))
        set("raw80", c.raw80.isEmpty ? "—" : c.raw80.hexString(separator: " "))
        set("rawDC", c.rawDC.isEmpty ? "—" : c.rawDC.hexString(separator: " "))
        set("rawBat", c.rawBattery.isEmpty ? "—" : c.rawBattery.hexString(separator: " "))
    }
}
