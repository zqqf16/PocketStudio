// HelpViewController.swift — 应用内新手帮助（中文）

import AppKit

@MainActor
final class HelpViewController: NSViewController {
    static let text = """
    # 快速开始
    1. 打开 Pocket 3，确保电量充足；手机上的 DJI Mimo 请彻底关闭（它会占用相机）。
    2. 在「设置」中填写相机 Wi-Fi 名称与密码（见下文「在哪里找 Wi-Fi 名称和密码」）。
    3. 点击工具栏「连接」。App 会：蓝牙扫描 → 配对 → 等待约 20 秒让相机开启 Wi-Fi → 加入相机 Wi-Fi → UDP 握手 → 显示画面。
    4. 首次蓝牙配对时，相机屏幕上可能会弹出确认，请点「允许/确认」。

    # 在哪里找 Wi-Fi 名称和密码
    - 相机 Wi-Fi 名称通常形如 OsmoPocket3-XXXX（XXXX 为 4 位字符）。
    - 在相机触摸屏上从顶部向下滑，进入设置（齿轮图标），找到「无线连接 / Wi-Fi」相关菜单，可以看到热点名称与密码。不同固件版本菜单名称可能略有不同。
    - 也可以在手机 DJI Mimo 连接相机时，在手机 Wi-Fi 设置里看到同名热点；密码可在相机菜单中查看。
    - 还没开过 Wi-Fi 也没关系：本 App 的蓝牙步骤会唤醒相机热点，之后在 Mac 的 Wi-Fi 列表里就能看到。

    # 权限说明（macOS 会询问）
    - 蓝牙：用于唤醒相机 Wi-Fi。若误点了「不允许」：系统设置 → 隐私与安全性 → 蓝牙 → 打开 PocketStudio。
    - 本地网络：用于与 192.168.2.1 通信。若误拒：系统设置 → 隐私与安全性 → 本地网络 → 打开 PocketStudio。没有此权限时，握手会一直超时。
    - 定位服务（可选）：macOS 规定 App 读取 Wi-Fi 名称需要定位权限。授予后 App 才能自动加入相机 Wi-Fi；不授予也能用，只是需要你手动在菜单栏选择相机 Wi-Fi。

    # 为什么有时要手动加入 Wi-Fi？
    - macOS 对 App 自动切换 Wi-Fi 有严格限制。本 App 会先尝试自动加入（CoreWLAN），失败时在「连接」页显示手动步骤：拷贝密码 → 菜单栏 Wi-Fi 图标中选择相机热点 → 粘贴密码加入。
    - 连上后 App 会自动检测到 192.168.2.x 地址并继续，无需其它操作。
    - 注意：连上相机 Wi-Fi 后，Mac 将暂时无法上网（相机热点没有互联网），这是正常的。

    # 操控
    - 实时取景为沉浸式：画面铺满窗口（黑边自动留白，横拍 / 竖拍 / 4:3 / 1:1 都按相机真实画面比例显示）。鼠标 3 秒不动，控件与鼠标指针自动淡出，移动鼠标即淡入；录制中、未连接、恢复中或正在操控时控件保持显示。
    - 沉浸模式 ⌃⌘I：收起侧边栏和工具栏；全屏 ⌃⌘F（或绿色按钮），全屏时工具栏自动隐藏；「显示 → 窗口适配画面比例」⌥⌘0 让窗口与画面比例一致（去黑边）。
    - 顶部遮罩显示录制 / 模式信息，底部遮罩显示连接、电量、SD 卡、云台姿态、帧率等状态。
    - 画面右侧是竖向深色「相机侧栏」（从上到下）：
      ① 模式：慢动作 / 录像 / 拍照 / 延时（黄色高亮 = 相机当前模式，点一下切换；录制中不可切换）；
      ② 圆形快门：白色圆 = 拍照，红色圆 = 开始录制，红色方块 = 停止录制，下方显示录制时长或当前模式；
      ③ 录制到 Mac（圆点图标，录制时变红）与截图；
      ④ 云台：回中（准星）、紧急停止（手掌）、云台菜单（陀螺仪图标：跟随 / 方向锁定 / FPV、相机端转速、手动速度 0.1–0.9、前后翻转）。
    - 左下角为虚拟摇杆。
    - 空格 / Return：按快门（与 iOS 相机一致）。P 只拍照，O 开始/停止相机录制，M 循环切换模式。
    - 方向键 / W A S D：按住转动云台，松开即停。Q / E：慢速左右；R / F：慢速上下。Esc 或 .：紧急停止云台（原来的空格已改为快门）。C：云台回中。数字 1–9：云台速度。V 显示/隐藏画面，I 显示统计。
    - 拍照后 Pocket 3 可能自动进入回放预览，实时画面会暂停；App 会自动发送「退出回放」，画面上显示「相机进入回放，正在退出回放…」，一般 1–3 秒恢复。
    - 画面左下角的虚拟摇杆可拖动；在画面上按住鼠标拖动也能控制；触控板双指滑动可微调。
    - 「录制到 Mac」把相机传来的视频流保存到「影片/PocketStudio」（MP4 或原始 H.264，可在设置中选择）。这与相机自身录制到 SD 卡是两回事。

    # 常见问题
    - 扫描不到相机：确认相机已开机且在 Mac 旁边；关闭手机蓝牙或退出 DJI Mimo；在设置中加大蓝牙扫描时间。
    - UDP 握手超时：确认已连上相机 Wi-Fi；确认已允许「本地网络」；退出 Mac 上的 DJI Mimo；在设置中切换「BSD Socket 兼容模式」重试；或关闭「仅通过 Wi-Fi 网卡发送」。
    - 连接成功但没有画面：点击工具栏「刷新视频」（等待相机释放旧会话后重建连接，仍失败会自动用蓝牙重新唤醒）；或断开后重新连接。
    - 经常断开 / 自动重连：App 会按 1s → 3s → 5s → 8s… 退避重试，每次都用蓝牙重新唤醒相机（与手动「连接」相同，成功率最高），若 Mac 已掉出相机 Wi-Fi 会自动重新加入。重连时画面保留最后一帧并压暗，窗口大小不会跳动。多次失败才会停下并提示。
    - 画面花屏几帧后自己恢复：这是丢包后相机的帧内刷新在修复画面，属正常；App 不再因此重建连接。
    - 云台没反应：刚连上时状态栏会显示「云台准备中…」，约 1 秒后即可操控；若一直如此，点「刷新视频」或重新连接。
    - 拍照没反应：相机需处于「拍照」模式（M 键切换），录像模式下相机会拒绝快门（日志显示「当前模式不支持」）。
    - 录制到 Mac 没有文件：开始录制时会自动请求关键帧，画面可能闪一下；请至少录几秒。点工具栏「查看文件」在访达中找到录制。
    - 画面卡顿：靠近相机，远离其它 2.4/5GHz 干扰源。
    """

    override func loadView() {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 28, height: 24)
        tv.textStorage?.setAttributedString(Self.render(Self.text))
        tv.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    /// 极简 Markdown 渲染（标题 / 列表 / 段落）
    static func render(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let p = NSMutableParagraphStyle(); p.paragraphSpacing = 6; p.lineSpacing = 2
            if line.hasPrefix("# ") {
                p.paragraphSpacingBefore = 14
                out.append(NSAttributedString(string: String(line.dropFirst(2)) + "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]))
            } else if line.hasPrefix("- ") {
                p.headIndent = 18; p.firstLineHeadIndent = 4
                var a = body; a[.paragraphStyle] = p
                out.append(NSAttributedString(string: "•  " + line.dropFirst(2) + "\n", attributes: a))
            } else if !line.isEmpty {
                p.headIndent = 18
                var a = body; a[.paragraphStyle] = p
                out.append(NSAttributedString(string: line + "\n", attributes: a))
            }
        }
        return out
    }
}
