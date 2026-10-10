# AGENTS.md — PocketStudio 交接文档（给 AI 编码代理 / 开发者）

> 主要用中文书写，代码标识符保持英文。修改代码前请通读本文件，尤其是「并发约定」和「已踩过的坑」。

## 1. 项目目的

**PocketStudio** 是一个原生 macOS 26 应用（纯 Swift + AppKit，**不使用 SwiftUI**）。名字不带型号：当前只接 **DJI Osmo Pocket 3**，标识符和目录按系列预留，以便以后加 Pocket 4 / Pocket 4P。连接流程：
蓝牙唤醒相机 Wi-Fi 热点 → 加入热点 → UDP 私有协议握手 → 接收并硬件解码 H.264 实时画面 → 拍照 / 录像 / 切换模式 / 云台 PTZ 控制 / 状态显示 / 将视频流录制到 Mac。界面文字为简体中文。

## 2. 来源

- 协议逐字节移植自 Python 项目 **sniffingpickles/DJI-Wifi-Connect**（`pocket3/duml.py`、`ble.py`、`udp_protocol.py`、`camera.py`、`gimbal.py`、`video.py`、`wifi.py`、`main.py`、`web.py`）。
- 额外的云台命令（回中 / 绝对角度 / 云台模式）参考 **yigitkonur/lib-osmo-ble** 的 `PROTOCOL.md`（原为 BLE；在 Wi-Fi 链路上 **未经实机验证**，UI 中标注「实验」）。
- 单元测试中的参考字节向量由原 Python 代码生成。

## 3. 目录结构

```
project.yml                     XcodeGen 配置（唯一可信来源；.xcodeproj 由它生成）
PocketStudio.xcodeproj/        生成物，勿手改
Tools/run-linux-tests.sh        在 Linux/macOS 上用 SwiftPM 编译 Core 并运行测试（Swift 6.2+）
README.md                       面向用户的中文说明（含新手指南）
AGENTS.md                       本文件
PocketStudio/
  App/        main.swift（纯 AppKit 启动）、AppDelegate（菜单）、AppModel（连接编排 + 全局状态）、AppSettings（UserDefaults + 钥匙串）
  Core/       平台无关、可在 Linux 编译测试的协议层
    CRC.swift               CRC8(init 0x77) / CRC16(init 0x3692) 查表
    ByteIO.swift            Bytes = [UInt8]；LE 读写、hex
    DUML.swift              DUML 封包/解析（0x55 SOF）
    UDPFrame.swift          9004 端口 UDP 8 字节头、握手包、ACK 包、命令包
    DJISessionCore.swift    会话状态机（序号、ACK、心跳、视频启动序列、DUML 分发）——无线程、无定时器
    CameraProtocol.swift    相机状态解析 + 相机命令
    GimbalProtocol.swift    云台负载构造（速度、绝对角度、模式）
    GimbalSpeedController.swift  云台速度状态机：轴顺序 / 反转 / 可靠停止 / 看门狗 / nudge
    DJIBLEMessage.swift     DJI BLE 帧、广播识别、配对 / Wi-Fi / RTMP 命令
    H264AnnexB.swift        Annex-B → NAL → 访问单元（AVCC）
    Link/DatagramTransport.swift  传输协议 + BSD socket 实现（兼容模式）
    Link/CameraLink.swift   把 DJISessionCore + 传输 + 定时器 组装在一个串行 queue 上
  Platform/   macOS 专属
    BLEManager.swift        CoreBluetooth（@MainActor，async/await 桥接）
    WiFiManager.swift       CoreWLAN 加入网络 + getifaddrs 检测 192.168.2.x + 系统设置跳转
    LocalNetworkPermission.swift  主动触发并检测「本地网络」权限（Bonjour 监听 + 浏览）
    NWDatagramTransport.swift     Network.framework UDP（默认传输）
    H264Decoder.swift       VideoToolbox 解码
    VideoPipeline.swift     解析 → 解码 → 显示 / 录制 / 截图（自有串行 queue）
    StreamRecorder.swift    .h264 原始流或 .mp4（AVAssetWriter 直通，不重编码）
  Views/      AppKit 界面（NSSplitViewController + NSToolbar + NSGlassEffectView）
    MainWindowController / LiveViewController（实时画面 + 叠加控件 + 状态栏 + 键盘/触控板）
    ConnectViewController / StatusViewController / DebugViewController（DUML 日志、原始命令、BLE RTMP）
    HelpViewController / SettingsWindowController / OnboardingWindowController
    VideoView（AVSampleBufferDisplayLayer）/ JoystickView / UIKitHelpers（UI 工厂方法）
  Resources/  Info.plist、PocketStudio.entitlements、Assets.xcassets
PocketStudioTests/  CoreProtocolTests、CameraLinkLoopbackTests（本地 UDP 假相机）、GimbalControlTests
```

## 4. 数据流

1. **BLE 唤醒**（`BLEManager`，可在设置中跳过）：扫描厂商数据 `AA 08` + 型号 `20 00`（OsmoPocket3）→ 连接 → 订阅 `FFF4` 通知、写 `FFF5` → 发送配对消息（id `0x8092`）。收到任何应答即视为成功；相机约 20 秒后开启 Wi-Fi 热点。加入 Wi-Fi 期间 **保持蓝牙连接**（否则相机可能关闭热点），成功后断开。
2. **加入 Wi-Fi**（`WiFiManager`）：CoreWLAN `scanForNetworks` + `associate`（需要定位权限才能读 SSID）。失败则降级为「手动加入」引导，轮询 getifaddrs 等待获得 `192.168.2.x` 地址（不依赖定位权限）。
3. **UDP 握手**（`CameraLink`/`DJISessionCore`）：向 `192.168.2.1:9004` 发送握手包（type 0x00），采用相机回复中的 session ID。
4. **保活**：ACK 每 20ms（type 0x04，带 video/telemetry/cmd 接收序号）；相机心跳 Camera:0x8E 每 200ms（每 5 拍附 0xA0、每 10 拍附 0x61）；云台速度 Gimbal:0x01 30Hz。
5. **视频启动**（握手后 0.5s）：PUSH General:0x88 → DM368(1)；WRITE General:0x81 / 0x82 → DM368(2)（「客户端注册」）；然后视频心跳 General:0x4F → DM368(2) 每 200ms（负载 `01 00 XX 00 00 ff ff ff ff`，每个计数值发两次；每 10 拍重新注册，**每 5 拍（1Hz）重发 0x88**——OpenPocketCine：相机在最后一次注册 8–10s 后停发视频）。同时发送 **0x03/0xDA 云台初始化** `05 FF FF FF FF` → type 3 id 0（1s、3s 补发）。
   - **云台就绪门控**：收到首个 Gimbal:0x05 且距视频启动 ≥0.6s 才放行非零速度；4s 无姿态则强制放行并继续补发初始化。状态栏显示「云台准备中…」。
6. **接收**：type 0x02 = 视频（去掉 12 字节窗口/帧信息后为 Annex-B H.264）→ `VideoPipeline`；type 0x01/0x05 = 遥测/命令（内含 DUML）→ 状态解析 + 调试日志。

## 5. 协议速查

- **UDP 头（8B）**：`[len|0x8000 LE16][session LE16][seq LE16][type][XOR(前 7 字节)]`。type：0 握手、1 遥测、2 视频、3 ACK_TELEM、4 ACK、5 命令、6 ACK6。
- **DUML**：`0x55 | len(10bit)+ver | CRC8(前 3B) | sender | receiver | seq LE16 | cmdType/ack | cmdSet | cmdID | payload | CRC16`。设备：1 相机、2 App、4 云台、8 DM368、13 ESC(电池)。flags 字节 = cmdType<<5：**0 = notify（0x00，无应答）、2 = request（0x40，需应答）、4 = 0x80（write/应答）、6 = 0xC0（response）**。⚠️ 原 Python 把 0 叫 REQ、2 叫 PUSH，语义正好反了；`DUMLCmdType` 已改名（`notify` / `request` / `write` / `response`），`sendReq` = notify、`sendPush` = request 仅为兼容旧名保留。
- **相机命令（cmdSet 2，全部 flags 0x40，来源 OpenPocketCine `Commands.swift`，Pocket 3 实机抓包）**：
  - 快门 `0x02/0x01 [01]`（录像模式下应答 `d9`）；录像开始/停止 `0x02/0x02 [01]/[00]`（不是开关，录制中再开始应答 `df`）；延时摄影开始/停止走 `0x02/0x01 [01]/[00]`。
  - 拍摄模式 `0x02/0xE1 [mode]`：慢动作 00、录像 01、延时 02、**拍照 05（Pocket 3；Pocket 4 是 0x17）**、移动延时 0A、全景 0C、夜景 28。**不要扫描其它取值**（OPC 报告扫描卡死过 Nano）。
  - 原 Python 的 0x20/0x21 录制、0x02 切模式、flags 0x00 发送 —— 实机日志里相机对它们没有任何应答，已废弃。
  - 应答（flags 0x80/0xC0）由 `CameraLink.onReply` 上报，`AppModel.handleReply` 在日志里显示「相机应答 · 录像：成功 / 错误码」。
- **状态解析**（OPC `CameraStatus.swift`，已用实机日志字节写成单测 `CameraCommandTests`）：Camera:0x80 **u32@0 bit7 = 录制中**、@5/@9 存储总量/剩余 MiB、@29 u16 = 已录秒数、**@57 = 拍摄模式（0xE1 取值）**；Camera:0xDC SD 总量/剩余 @6/@10；ESC:0x02 offset 1 LE16 = 毫伏、offset 20 = 电量 %；Gimbal:0x05（49–50B）：**i16@4 = yaw、−i16@20 = 俯仰（上正）**、i16@0 = 原生 pitch、@6 高 2 位 = 模式（0 方向锁定/1 FPV/2 跟随）。原 Python 的 0x80 / 0x05 解析是错的（日志 `01 02 80 00…` 被误读）。设置「旧版姿态解析」可切回原布局。
- **云台速度 Gimbal:0x01（10B）**：`[字段0 LE16][roll=0][字段2 LE16][0x8000][0x0042]`，速度值 0…2048，中位 1024（`GimbalProtocol.speedValue`，向零截断与 Python 一致）。
  - ⚠️ **轴顺序**：**实机 Pocket 3 确认为 `[pitch, roll, yaw]`**（与 lib-osmo-ble 一致）；原 Python 命名为 `[yaw, roll, pitch]`，照搬会导致上下/左右互换。默认 `GimbalAxisOrder.pitchRollYaw`，设置中可切回。
  - UI 语义：yaw 右为正，pitch 上为正；每轴可在设置中反转（默认不反转；**实机方向正负尚需确认**）。
- **云台停止逻辑**（`GimbalSpeedController`，单测覆盖）：`stop()` 立即发零速并在随后 tick 补发，共 `stopRepeats = 4` 次（30Hz ≈ 100ms）；停止后 30Hz 循环只发零速（所有调用都在 `CameraLink.queue` 串行，无竞态）；连续输入 >300ms 无刷新 → 看门狗归零；`nudge` 到期自动停止且不受看门狗影响。UI 端（`LiveViewController`）：mouseUp / 摇杆松开 / keyUp / 空格 / 触控板 phase 或 momentum 结束 / 窗口失焦、最小化、关闭 / App 失活或隐藏 / 视图消失 → `stopAllGimbalInput()`；按住期间每 100ms 重发速度以喂看门狗，并用 `NSEvent.pressedMouseButtons` 检测丢失的 mouseUp。
- **云台模式 / 回中（0x04/0x4C，flags 0x40）**：回中 `FE 08`、前后翻转 `FE 09`、跟随 `02 08`、FPV `01 08`、方向锁定 `00 08`；转速 `0x04/0x50 00 05 01 <0快/1默认/2慢>`。回中前先发零速 + `0x04/0x14 00×6 04 01`（打断残留定时移动）。
  - ⚠️ 旧版把 lib-osmo-ble 的 `0x14 [0,0,0,0,0,0,07,FF]` 当回中：0x14 字段实为 `[yaw, roll, 原生pitch, mode, 时长×0.1s]`，原生 pitch 0 ≈ 抬头极限，时长 25.5s —— 这就是「点回中后云台一直上仰停不下来」的根因。
  - 右下角「✋」按钮 = 紧急停止（零速 ×4），只在输入异常导致仍在转动时使用。
- **BLE 帧**：`0x55 | len | 0x04 | CRC8 | target LE16 | id LE16 | type LE24 | payload | CRC16`；配对 id 0x8092 target 0x0702 type 0x450740；另有停止推流 / 准备直播 / 配置 Wi-Fi / 开始 RTMP 命令（`DJIBLE`）。
- **本地网络权限**：Info.plist 必须同时有 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`（`_pocketstudio._tcp` / `_udp`）。`LocalNetworkPermission.request()` 启动 NWListener 广播 + NWBrowser 浏览该服务，立即弹窗；`.waiting(.dns(-65570 kDNSServiceErr_PolicyDenied))` = 已拒绝，浏览到结果 = 已允许，20 秒超时 = 未能确认；UDP 握手成功也会标记已允许。结果存 UserDefaults `localNetworkPermission`。

## 5b. 画面冻结 / 命令通道卡死（2026-10-10 实机日志）

- **现象**：画面冻结，同时云台失灵，但 0x80 / Gimbal:0x05 等 NTFY 推送照常；原地重新握手无效，断开重连立刻恢复。
- **日志证据**：冻结期间（11:41:37–11:42:05）我们发了 174 个 0x8E、170 个 0x4F、34 个 0x88（全部 flags 0x40），相机 **0 个应答**；
  用户在 11:42:00–01 发了 41 个非零云台包，无效。11:41:49 原地重新握手后（我们的 seq 从 60832 跳到 1736）仍 0 应答。
  11:42:11 断开重连（新 socket）后 11:42:12.157 立即恢复应答（约 11 个/秒）。⇒ 卡死的是**可靠命令/应答窗口**，不是解码器。
- **根因（中-高置信）**：ACK（pktType 0x04）三组游标填错（与原 Python 相同）：
  1. 组 1（可靠应答）初始化为我们自己的握手随机种子，且只接受「比它靠前」的 seq —— 相机 seq 空间与种子无关时约一半概率永不前进；
  2. 组 2 填我们自己的 cmdSeq：~70 包/秒 × 8，约 1 分钟跨过半个序号环；
  3. 命令头 ack 字段 seq−32 与尾部 0x60（「无人机」布局），OPC 的 Pocket 布局是 seq−8 与 00（OPC：写错会「静默丢弃写命令而读照常」）。
  另外 0x4F（原项目叫「视频心跳」）其实是**文件分块读取**：相机每次回 265 字节（固件 XML），以 5Hz 大量占用可靠窗口，放大了游标错误的影响。
- **修复**：游标首次见到即采用、之后只前进；34 字节 0x01 遥测播种组 1/2；组 2 无遥测时用 baseSeq；命令头改 OPC 布局（设置「使用原 Python 的 UDP 命令头」可切回）。
- **看门狗**（`VideoHealthMonitor`，单测覆盖）：遥测在、但 1.5s 无解码帧 → 阶段 1（视频包在到：重建解码器 + 冲刷渲染器 + 0x09/0xA8 请求 IDR；视频包不到：重新注册 + 请求 IDR）→ 2.5s 后阶段 2 原地重新握手 → 3s 后阶段 3 新 socket 重建链路 → 之后每 10s 重建。遥测也停 = 链路中断，不做视频恢复。画面中间显示「画面中断，正在恢复…」。
- **「刷新视频」** = `rebuildLink`：停旧链路（零速）→ 清空解码/渲染/GOP → 新传输 + 新 CameraLink（新 session、序号、游标、云台就绪）。
- **解码器**：旧版会话失效时只清 session 不清 formatDescription → 永不重建（永久冻结）；已修。连续 3 个解码错误 → 等 IDR 并请求。渲染器 `.failed` / `requiresFlushToResumeDecoding` → flush。
- **队列**：网络/ACK/云台 = `CameraLink.queue`；拆包/解码/显示 = `VideoPipeline.queue`；录制写盘 = `VideoPipeline.recQueue`；主线程只读锁内快照（不再 `queue.sync` 到视频队列）。
- **诊断日志**：已连接时每 10s（冻结时每 2s）一行 `[诊断] 视频片段 n/s · AU · 解码 fps · 最近：视频包/解码/遥测/应答 · 相机应答 n/s · ACK v/r/x · 握手次数 · 解码错误 · 渲染器 · 等关键帧 · GOP · 录制排队 · 待解码 · 主线程最大延迟 · 云台`。
  判读：相机应答 0/s 且视频包「从未/很久」= 命令窗口卡死；视频包在到但解码很久 = 解码/渲染问题；ACK 后带 `?` = 游标尚未同步。
- **未解决的疑点**：相机每秒向我们发 REQ General:0x81（DM368(2)，`hg212…`）、偶发 REQ 0x88 `19 00`、0x74 `29 01`，我们从不应答；语义未知，未实现。

## 5c. 断线 / 自动重连 / 拍照后黑屏（2026-10-10 13:33 实机日志 6ef4d6a2…）

日志证据与结论：
1. **看门狗亲手杀死健康链路（高置信）**：13:33:54 丢包 → `-12909` → v1 进入「等 IDR」；但 Pocket 3 实时流几乎不发 IDR（诊断 `GOP 716` ≈ 24s 无关键帧；`等关键帧 是(丢 128)`），
   同时 `视频片段 546/s · 相机应答 12/s` 完全健康。v1 仍在 13:33:59 原地重新握手、13:34:02 重建 → 握手超时 → 彻底断。
   修复：`VideoPipeline` 解码错误不再等 IDR（最多等 1.2s 就直接解 P 帧，帧内刷新自愈）；`VideoHealthMonitor` v2：视频包在到 = 只重建解码器，绝不动链路；删除「原地重新握手」阶段（三份日志里从未奏效）。
2. **拍照后相机进入回放（高置信，现象）/ 退出回放可恢复（中，未实测）**：13:35:00.462 快门 → RSP 00；之后 0x80 标志 `0x84→0x8C`（处理中），13:35:03.7 起 10Hz `Camera:0x82`（回放参数推送），
   13:35:04.4 标志 bit30（OPC `inPlayback`）置位，视频停（13:35:05 `视频包 1.7s`），相机不再应答（`应答 5.1s`）。
   修复：`CameraStatus.inPlayback/capturing`；`AppModel.handlePlayback` 每 2s 发 `0x02/0x0C 01 01 00 00`（OPC exitPlayback）直到清除；相机忙时看门狗 `.waitCameraBusy` 不升级。设置可关。
3. **重建链路总是握手超时，手动重连成功（高置信）**：13:34:02 与 13:35:11 的重建（关旧 socket 300ms 后立即握手）都 10s 超时；13:34:27 手动「连接」（蓝牙配对 → 已在相机 Wi-Fi → 握手）一次成功。
   失败后 `link=nil`，看门狗用空快照误报「画面已恢复」（13:35:21）、`相机应答 -36.0/s`。
   修复：`ReconnectPolicy`（1.5/3/5/8/15/30s 退避，最多 8 次）：第 1 次 = 等 ≥1.5s 让相机释放旧会话 + TCP 7001 SetPairingPIN（OPC：Pocket 系列握手前戳一下并保持 TCP）+ 新 socket；
   之后 = 完整重连（蓝牙重新配对唤醒，若 Mac 已不在相机 Wi-Fi 则重新加入）。`link==nil` 或重连中看门狗不运行；应答速率在新链路时清零且不为负。
4. **相机发来的未应答请求（0x81 "hg212"、0x88 `19 00`、0x74 `29 01`）不是断线原因（中）**：健康期（13:34:39–13:35:00，应答 11–12/s）它们同样每 1/2/4s 出现且未应答；OPC 也不应答。保持不答。
5. 主线程最大延迟 4526ms 出现在连接阶段（CoreWLAN 同步调用），连上后 ≤150ms，非断线原因。

### UI（同一轮）
- 统一快门 `ShutterButton` + 模式分段控件（`Shutter` / `CaptureModeState` 纯逻辑在 Core，有单测）；空格/Return = 快门，Esc/. = 云台急停。
- 稳定布局：画面放固定宽高比容器（默认 16:9，仅解码尺寸变化 >1% 才改）；恢复期间保留最后一帧（flush 不移除图像）+ 压暗层；覆盖层标签不参与固有尺寸。

## 5d. 命令通道「停止应答」→ 断线（2026-10-10 13:51 实机日志 9fdb5d93…）

5 次断线完全同一模式（诊断行）：先是 `应答` 年龄开始增长、`相机应答 0.0/s`、ACK `r`/`x` 冻结（相机不再发可靠通道 0x03 包），
而视频 30fps、遥测正常；8–10s 后视频停止（相机约 10s 收不到被应答的注册就停视频）；看门狗重新注册无效 → 重连。
| 会话 | 应答停止 | 视频停止 | 触发前 |
|---|---|---|---|
| 1:51:39 | ≈1:52:02 | 1:52:10 | 7s 内连切 6 次模式（最后一次 1:52:05 无应答） |
| 1:52:34 | ≈1:52:37 | 1:52:45 | 连接后 3s（启动突发） |
| 1:53:10 | ≈1:53:13 | 1:53:21 | 同上 |
| 1:53:45 | ≈1:53:55 | 1:54:04 | — |
| 1:54:28 | 1:54:51.36（最后一条 RSP 0x8E） | 1:55:00 | 快门（d8 = 无 SD 卡）后 |
当时 App 发送约 47 条命令/s：30Hz 云台零速（静止也发）+ 0x8E 5Hz + 0x4F 5Hz（均要求应答，≈12 应答/s）+ 其他。OPC 原话：“overlapping Tasks flooded the camera so replies stopped”；OPC/Mimo 云台只在按住时发、GET ~1Hz。
结论（中高置信）：命令过密 + 突发 → 相机可靠通道卡死且不会自愈。
修复：云台静止不再发包（streaming 默认关，松手补发 stopRepeats 次零速）；0x8E/0x4F 降为 1Hz，0xA0 2s、0x61 5s、0x81/82 5s（0x88 保持 1Hz）；
用户命令间隔 ≥300ms；模式切换防抖 400ms 只发最后一次；看门狗 `.commandStall`：应答 6s 无 → 立即重连（不等视频死）。
重连：UDP 原地重建 0/5 成功、蓝牙唤醒 5/5 成功 → `ReconnectPolicy.rebuildAttempts = 0`，直接蓝牙唤醒（1s 后）。

## 5e. 沉浸式取景 UI（2026-10-10 14:10）

- 画面全出血（`UI.pin(videoView, to: view)`），比例完全交给 `AVSampleBufferDisplayLayer.videoGravity = .resizeAspect`，不再有宽高比约束 → 竖拍 / 4:3 / 1:1 自动正确、视图尺寸恒定无跳动。
  `H264Decoder.dimensions` 改用 `CMVideoFormatDescriptionGetPresentationDimensions(usePixelAspectRatio:true, useCleanAperture:true)`。
- 深色材质：`HUDPanel`（NSVisualEffectView `.hudWindow` + darkAqua + 黑色 28% 压暗 + 描边 + 阴影）用于右侧相机栏、摇杆、统计、恢复提示；浅色 Liquid Glass 在亮画面上不可读（用户截图）。
- `ScrimView` 顶 / 底黑色渐变（不拦截点击）；状态栏移入底部遮罩；模式选中 = 强调色胶囊。
- 自动隐藏：`LiveViewController.pokeChrome()`，NSTrackingArea mouseMoved；3s 后淡出（`chromePinned` 为真时不隐藏），并 `NSCursor.setHiddenUntilMouseMoves`。
  沉浸 / 全屏时红绿灯随之淡出（`MainWindowController.liveChromeChanged`）。
- `MainWindowController.toggleImmersive`（⌃⌘I）、全屏 `.autoHideToolbar`、`fitWindowToVideo`（⌥⌘0）。

## 5f. 拖动云台后断线（2026-10-10 14:17 实机日志 1f0f39c2…）

每秒云台 TX 包数 vs 相机应答（RSP）：2:17:22 **84**/2:17:23 76 → 2:17:23 起 RSP=0；2:17:37 **83**/2:17:38 73 → 2:17:39 起 0；2:17:59 **71** → 2:18:00 起 0；
61/59 包/s 的秒未出事。每次随后 6s 触发 `.commandStall` → 蓝牙重连。拖动期间同一毫秒出现两包（如 2:17:22.000/.001、.034/.034），
因为 `setGimbalSpeed` 对每个 mouseDragged 都立即发包，叠加 30Hz tick 与 100ms 保活；空闲时设置项「30Hz 持续发送」（默认 true）仍发 30 包/s。
摇杆包本身是 NTFY（0x00，不要应答）——不是 request 导致，是**包速率**过高（高置信）。
修复：云台包硬上限 25Hz（`GimbalProtocol.minInterval = 0.04`，= OPC `GimbalStick.streamInterval`）：`setGimbalSpeed` 只更新目标值，
仅在开始/停止沿且距上次 ≥40ms 时立即发；tick 25Hz 合并发送最新值；停止被限速时改为补发；移除「持续发送」（强制关）。
单测：250 事件/s 拖动 2s → ≤52 包；摇杆包为 notify。

## 6. 并发 / 隔离约定（Swift 6.2）

- 工程设置：`SWIFT_VERSION 6.0`、`SWIFT_STRICT_CONCURRENCY complete`、`SWIFT_DEFAULT_ACTOR_ISOLATION MainActor`、Approachable Concurrency（`NonisolatedNonsendingByDefault`、`InferIsolatedConformances`）。
- **所有类型显式声明隔离**，不依赖默认值（两种默认隔离下都应能编译；Linux 测试脚本两种都测）：
  - `Core/` 全部 `nonisolated`（类型和 extension 都要写）；值类型 `Sendable`；有状态类（`CameraLink`、`BSDDatagramTransport`）只在自己的串行 queue 上访问并标 `@unchecked Sendable`；跨线程回调一律 `@Sendable` 闭包。
  - `NWDatagramTransport`、`H264Decoder`、`StreamRecorder`、`VideoPipeline`：`nonisolated` + 串行 queue。
  - `BLEManager`、`WiFiManager`、`LocalNetworkPermission`、`AppModel`、`AppSettings`、`AppDelegate`、所有视图/控制器：`@MainActor`。
  - 委托：`@preconcurrency CBCentralManagerDelegate` 等一致性 + MainActor 方法（委托队列为主线程）；框架 import 使用 `@preconcurrency`。
  - 后台 → 主线程：`Task { @MainActor in … }`；Timer / NotificationCenter(queue: .main) 闭包内用 `MainActor.assumeIsolated`。
  - 不要在 `@Sendable` 闭包里捕获非 Sendable 框架对象（NWConnection、CWInterface、AVAssetWriter 等）；需要时用 ObjectIdentifier、在闭包内重新获取，或 `@unchecked Sendable` 小盒子（见 `WriterBox`、`RendererBox`）。
- 测试类标 `nonisolated`；测试回调里累积数据用 `Locked<T>`。

## 7. 构建与测试

- **macOS**：Xcode 26 / macOS 26 SDK。`brew install xcodegen && xcodegen generate`，打开 `PocketStudio.xcodeproj`，选择签名团队后运行。部署目标 macOS 26.0。未开启 App Sandbox（CoreWLAN 加入网络在沙盒中受限）。
- **测试**：Xcode 中 ⌘U；或 `Tools/run-linux-tests.sh`（Swift 6.2+，`-warnings-as-errors`，默认 MainActor 隔离）；`ISOLATION=nonisolated Tools/run-linux-tests.sh` 测另一种默认值。当前 32 个测试全部通过。
- 新增 Swift 文件后需重新 `xcodegen generate`（Linux 上可自行编译 XcodeGen）。

## 8. 已踩过的坑（及修复）

1. **Swift 6 不再从协议一致性推断 @MainActor**：`AppDelegate: NSApplicationDelegate` 是 nonisolated → 调用 `model.connect()` 报错。修复：显式 `@MainActor`。
2. **默认 MainActor 隔离让 Core 类型被隔离**，导致奇怪的重载错误（如 "Cannot convert Int to (UInt8) throws -> Bool"）。修复：Core 全部 `nonisolated`。
3. **nonisolated 类中的 `lazy var`** 报 "'nonisolated' cannot be applied to mutable stored properties"。修复：改为 `let`。
4. **`.authorizedWhenInUse` 在 macOS 不可用**；macOS 只用 `.authorizedAlways`（`.authorized` 同值）。`requestWhenInUseAuthorization()` 可用。
5. **`ArraySlice` 没有 `hexString`**：`payload.prefix(96).hexString()` 报 "Missing argument label 'while:'"。修复：`Bytes(payload.prefix(96)).hexString()`。
6. **云台轴互换**：Python 字段命名 `[yaw, roll, pitch]` 与实机不符 → 默认改为 `[pitch, roll, yaw]`。
7. **松手后云台继续转**：单次零速包可能丢失、旧速度可能被重发 → `GimbalSpeedController` 可靠停止 + 看门狗 + UI 全面停止钩子。
8. **「本地网络」按钮无反应**：单发 UDP 包不一定立即弹窗 → Bonjour 监听 + 浏览（需 `NSBonjourServices`），并检测结果。
9. **回中让云台一直上仰**：误用 0x14 定时绝对角度（见 §5）→ 改为 0x4C `FE 08`。
10. **云台模式切换无效**：旧负载 `[mode, 00]` 且取值 0/1/2 = 锁定/跟随/FPV、flags 0x00 → 正确为 `[mode, 08]`、0 锁定/1 FPV/2 跟随、flags 0x40。
11. **拍照/录制基本无效、录了停不下来**：命令 ID 错（0x20/0x21）、flags 0x00（notify，相机不处理）、录制状态位解析错（永远「未录制」→ 每次都发「开始」；日志 4 次「开始相机录制」0 次「停止」）。
12. **首次连接云台不响应**：缺 0x03/0xDA 初始化、视频启动后立刻发摇杆流 → 就绪门控 + 初始化补发（根因为推断，未实机复测）。
13. **「录制到 Mac」不生成文件**：Pocket 3 实时流只在流开始/重新握手时发 IDR，录制器一直等关键帧（日志 3 次「录制未生成文件」）。修复：`VideoPipeline` 缓存最近一个 GOP，开始录制时先写入；缓存不可用时自动重新握手请求 IDR；`StreamRecorder` 排队写入不丢帧。文件名改用 en_US_POSIX（之前带「上午」）。
14. **「查看」按钮没反应**：工具栏项不在默认工具栏且无 target；现在默认显示「查看文件」并显式 target，优先选中最近的录制，不存在则打开文件夹。

## 9. 已验证 / 未验证

- **已验证（Linux，Swift 6.2.3 编译 + 单测）**：CRC、DUML、UDP 头/握手/ACK/命令包与 Python 逐字节一致；状态解析；BLE 帧与识别；H.264 Annex-B 拆分与访问单元组装；`CameraLink` 与本地假相机的完整回环（握手、ACK、心跳、视频、注册、拍照、云台）；云台轴映射 / 停止 / 看门狗。
- **实机已确认（用户反馈）**：应用可在真实 Pocket 3 上构建运行；云台轴顺序 `[pitch, roll, yaw]`。
- **依据第三方实机抓包（OpenPocketCine）但本应用尚未实机复测**：相机快门/录像/模式命令、云台回中/模式/翻转/转速、0x03/0xDA 初始化、0x80/0x05 新解析、GOP 缓存录制。
- **未在 Linux 编译、仅人工审阅**：所有 `Platform/`、`App/`、`Views/` 文件（用户已在 Xcode 26 编译通过的版本之后的改动：云台 UI 停止钩子、`LocalNetworkPermission`）。
- **未实机验证**：云台方向正负（反转开关默认关）；roll 字段（@2，OPC 用四元数求）；BLE RTMP 直播流程；CoreWLAN 自动加入在各系统版本上的表现；本地网络授权检测（拒绝码 -65570 的实际触发）；MP4 录制的时间戳与 QuickTime 兼容性。

## 10. TODO / 开放问题

- [未实测] 退出回放命令能否让 Pocket 3 在拍照后恢复实时流；TCP 7001 戳对重连成功率的实际影响；bit18/19 = 拍照处理中 只是推断。
- 若拍照后仍黑屏：看日志「相机处于回放 → 发送退出回放」后 0x80 bit30 是否清除、是否有 0x02/0x0C 应答。


- 实机确认云台正负方向，必要时修改默认反转值并更新 `GimbalControlTests`。
- 用户复测：日志里应出现「相机应答 · 录像：成功」等；记录任何其它错误码。
- 摇杆速度范围：Mimo 用中位 1024 ±550、尾部 `00 80 22 00`；本应用沿用 Python 的 ±1024 与 `00 80 42 00`（实机可用）。
- 0x00/0x99 状态订阅（OPC 有，本应用未实现）。
- 视频断流自动恢复（目前需手动「刷新视频」= 重新握手）。
- 相机录制计时、更多相机参数（分辨率/帧率/ISO）解析与设置。
- 是否开启 App Sandbox（会影响 CoreWLAN 自动加入），以及公证 / 分发。
- 为 `LiveViewController` 输入层抽出可测试的纯逻辑（目前只在协议层有单测）。
