**中文** | [English](README.en.md)

# PocketStudio

用 Mac 通过 **蓝牙 + Wi-Fi** 连接 DJI Osmo Pocket 系列相机：实时取景、把视频流录到 Mac、拍照 / 录像 / 切换模式、用键盘 / 触控板 / 屏幕摇杆控制云台，并查看电量、SD 卡和云台姿态。

名字不带型号。**当前已支持 Osmo Pocket 3**；工程按系列来组织，方便以后接入 Pocket 4 / Pocket 4P。界面为简体中文。这是一个纯 Swift + AppKit 的原生 macOS 应用，不使用 SwiftUI。

协议逐字节移植自 [sniffingpickles/DJI-Wifi-Connect](https://github.com/sniffingpickles/DJI-Wifi-Connect)，云台回中 / 模式等命令参考 [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) 与 [OpenPocketCine](https://opencapture.org/openpocketcine/docs/) 的实机抓包。协议细节、并发约定和实机日志结论写在 [AGENTS.md](AGENTS.md)。

> 教育与研究用途，与 DJI 没有官方关系。协议来自社区逆向，可能随固件变化。本软件按 [MIT 许可证](LICENSE) 发布。
>
> 作者：[@zqqf16](https://github.com/zqqf16)

## 功能

- 蓝牙唤醒相机 Wi-Fi，再加入热点并完成 UDP 握手
- VideoToolbox 硬件解码 H.264 实时画面
- 拍照、开始 / 停止录像、切换拍摄模式（快门随当前模式变化）
- 键盘、触控板、画面拖动、屏幕摇杆控制云台；回中、跟随 / 方向锁定 / FPV、转速
- 电量、SD 卡、录制状态、云台姿态
- 把实时流保存到 Mac（MP4 直通封装，或原始 `.h264`）
- 断线按退避自动重连；拍照后若相机进入回放，会尝试退出回放以恢复预览

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 26（Tahoe）或更新 |
| Xcode | Xcode 26 或更新（需要 macOS 26 SDK） |
| 硬件 | 带蓝牙 4.0+ 与 Wi-Fi 的 Mac |
| 相机 | DJI Osmo Pocket 3（Pocket 4 / 4P 尚未实现） |
| 第三方依赖 | 无，只用系统框架 |

## 编译与运行

仓库里已经带有生成好的 `PocketStudio.xcodeproj`，克隆后可以直接打开。

```bash
git clone https://github.com/zqqf16/PocketStudio.git
cd PocketStudio
open PocketStudio.xcodeproj
```

1. Xcode 左上角选择 Scheme **PocketStudio**，运行目标选 **My Mac**。
2. 签名默认是「本机临时签名（Sign to Run Locally）」。若提示签名问题：选中工程 → TARGETS `PocketStudio` → **Signing & Capabilities** → Team 选你的 Apple ID（免费账号即可）。
3. 按 **⌘R** 运行。首次启动会打开新手引导。
4. 运行单元测试：**⌘U**。

修改了 `project.yml` 之后再生成工程：

```bash
brew install xcodegen
xcodegen generate
```

## 第一次连接

1. **彻底退出** 手机和 Mac 上的 DJI Mimo（它会占用相机，导致握手失败）。
2. 打开 Pocket 3。
3. 按新手引导授予权限：
   - **蓝牙**（必需）：唤醒相机 Wi-Fi 热点。
   - **本地网络**（必需）：与相机 `192.168.2.1:9004` 通信。
   - **定位服务**（可选）：macOS 规定读取 Wi-Fi 名称必须有定位权限；授予后 App 才能自动加入相机 Wi-Fi。不授予也可以手动加入。
4. 填写相机 **Wi-Fi 名称和密码**。名称通常形如 `OsmoPocket3-XXXX`。在相机屏幕上 **从顶部下滑 → 设置（齿轮）→ 无线连接 / Wi-Fi** 可以查看。不确定也没关系：连接时 App 会用蓝牙唤醒热点，热点会出现在 Mac 的 Wi-Fi 列表里。
5. 点击工具栏 **「连接」**。流程是：蓝牙扫描 → 配对（首次可能要在相机上点确认）→ 等待约 20 秒热点开启 → 加入相机 Wi-Fi → UDP 握手 → 启动视频 → 已连接。加入 Wi-Fi 期间会保持蓝牙连接，成功后再断开。

### 被系统拦住时

| 现象 | 原因 | 处理 |
|---|---|---|
| 扫描不到相机 / 「未获得蓝牙权限」 | 首次弹窗选了「不允许」 | 系统设置 → 隐私与安全性 → **蓝牙** → 打开 PocketStudio，然后重启 App |
| 「UDP 握手超时」 | 没有本地网络权限、没连上相机 Wi-Fi，或 Mimo 占用 | 系统设置 → 隐私与安全性 → **本地网络** → 打开 PocketStudio；确认菜单栏 Wi-Fi 是相机热点；退出 DJI Mimo。仍不行时在「设置」里切换 **BSD Socket 兼容模式**，或取消「仅通过 Wi-Fi 网卡发送」 |
| 连接页出现「请手动加入相机 Wi-Fi」 | macOS 不允许 App 自动切换 Wi-Fi（缺少定位权限，或受 MDM 限制） | ① 点「拷贝密码」② 打开 Wi-Fi 设置 ③ 选择 `OsmoPocket3-XXXX`，⌘V 粘贴密码并加入 ④ 回到 App，检测到 `192.168.2.x` 后会自动继续（最多等 3 分钟） |
| 列表里没有相机热点 | 热点还没起来 | 等约 20 秒，或再点一次「连接」让蓝牙重新唤醒 |
| 连上了但是黑屏 | 还没收到可显示的画面 | 工具栏「刷新视频」，或断开重连。恢复期间会保留最后一帧 |
| 连上相机后 Mac 不能上网 | 相机热点没有互联网 | 正常现象。断开后 Mac 会回到原来的网络 |

本地网络授权由 Bonjour 服务 `_pocketstudio._tcp` 触发。新手引导里点「请求」会弹出系统框，并显示未请求 / 等待授权 / 已允许 / 已拒绝。

App Sandbox **默认关闭**。CoreWLAN 自动加入 Wi-Fi 在沙盒里经常被拒绝，这个 App 也不准备上架 App Store。相关权限已经写在 `PocketStudio/Resources/PocketStudio.entitlements` 里；若要打开沙盒，把 `com.apple.security.app-sandbox` 改为 `true`（自动加入 Wi-Fi 届时可能只能走手动引导）。

## 操作

| 操作 | 方式 |
|---|---|
| 云台转动 | 按住 **方向键 / W A S D**（松开停止）；左下角摇杆；在画面上按住拖动；触控板双指滑动 |
| 慢速转动 | **Q / E**（左右）、**R / F**（上下） |
| 紧急停止云台 | **Esc**、**.** 或 ⌘. |
| 云台回中 | **C** / ⌘0 |
| 云台速度 | **1–9**（0.1–0.9），或右下角滑块 |
| 快门（随模式拍照，或开始 / 停止录制） | **空格 / Return**，或画面底部圆形快门（白圆 = 拍照，红圆 = 录制，红方块 = 停止） |
| 拍照 | **P** / ⇧⌘P |
| 相机开始 / 停止录制 | **O** / ⇧⌘R |
| 切换拍摄模式 | 快门左侧分段控件，或 **M** 循环。录制中不能切换 |
| 显示 / 隐藏画面 | **V** |
| 统计信息 | **I** |
| 录制视频流到 Mac | 工具栏「录制到 Mac」/ ⌥⌘R。文件在「影片/PocketStudio」，可选 MP4 或原始 H.264 |
| 截图 | 工具栏「截图」/ ⇧⌘S（PNG） |
| 刷新视频 | ⌘R（等待旧会话释放后重建连接；失败会用蓝牙重新唤醒） |
| 云台回中 / 模式 / 转速 / 前后翻转 | 右下角面板 / ⌘0 |

断线后按 1.5s → 3s → 5s → 8s… 退避重连，并用蓝牙重新唤醒（需要时再加入相机 Wi-Fi）。拍照后如果相机进入回放、预览停住，App 会发送退出回放。云台包有 25Hz 上限，避免把相机的命令通道打满。

## 目录

```
PocketStudio/
├── project.yml                  XcodeGen 工程描述（改目标、源文件后用它重新生成）
├── PocketStudio.xcodeproj       已生成的 Xcode 工程
├── PocketStudio/
│   ├── Core/                    平台无关协议层（Linux 上也能编译测试）
│   ├── Platform/                蓝牙、Wi-Fi、UDP、H.264 解码、录制
│   ├── App/                     启动、菜单、连接编排、设置
│   ├── Views/                   AppKit 界面
│   └── Resources/               Info.plist、entitlements、App Icon
├── PocketStudioTests/           协议、云台、相机命令、本机回环假相机
├── Tools/run-linux-tests.sh     不依赖 Xcode，用 SwiftPM 跑 Core 测试
├── LICENSE                      MIT
└── AGENTS.md                    给开发者 / 编码代理的协议与并发说明
```

Bundle ID：`com.pocketstudio.app`。

## 测试

```bash
# 需要 Swift 6.2+。macOS 上用 Xcode 自带工具链即可。
./Tools/run-linux-tests.sh
# 再测一次「默认隔离 = nonisolated」：
ISOLATION=nonisolated ./Tools/run-linux-tests.sh
```

测试覆盖 CRC、DUML、UDP 头 / 握手 / ACK、BLE 帧、相机与云台命令、状态解析、H.264 访问单元，以及对本机假相机的握手和视频回环。参考字节与上游 Python 逐字节对齐。

## 现状

- **Pocket 3 实机**：可以连接、出实时画面、控制云台。速度命令的轴顺序 `[pitch, roll, yaw]` 已在实机上确认。云台正负方向的默认值仍建议在设置里核对，必要时打开反转。
- **尚未支持**：Osmo Pocket 4、Pocket 4P，以及其他 DJI 机型。
- **协议层**：可在 macOS 和 Linux 上编译并跑单元测试。AppKit / CoreBluetooth / VideoToolbox 部分只在 macOS 上编译。

已知限制和实机上修过的问题（命令通道被打满、拍照后进入回放、看门狗误拆健康链路等）记在 [AGENTS.md](AGENTS.md)。

## 致谢

- [sniffingpickles/DJI-Wifi-Connect](https://github.com/sniffingpickles/DJI-Wifi-Connect) — 协议来源
- [eerimoq/moblin](https://github.com/eerimoq/moblin) — BLE 配对
- [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) — 云台扩展命令
- [OpenPocketCine](https://opencapture.org/openpocketcine/docs/) — Pocket 3 相机 / 云台命令与状态字段
- [samuelsadok/dji_protocol](https://github.com/samuelsadok/dji_protocol) — UDP 协议文档

## 许可证与联系

[MIT License](LICENSE) · Copyright © 2026 [zqqf16](https://github.com/zqqf16)

问题、实机日志和机型支持可以在 GitHub 上提 [Issue](https://github.com/zqqf16/PocketStudio/issues)。
