# AndroidConnection


--------------------------------------------------------

原生 macOS（SwiftUI + AppKit）的 Android 设备管理器：USB / 无线 ADB、文件管理、应用管理、实时投屏、**设备音频转发**、剪贴板与设备诊断。

- 通用二进制：Apple Silicon（arm64）+ Intel（x86_64）
- 系统要求：macOS 13 或更高
- 内置 Android platform-tools `adb`，无需安装 Android Studio
- 视频：scrcpy 视频服务端（H.264）+ VideoToolbox 硬件解码；支持低亮度护屏与手动物理熄屏，画面与触控继续
- 音频：内置 scrcpy 服务端捕获播放混音，PCM 直接交给 AVAudioEngine



## 功能

### 设备

- USB 与无线 ADB 发现，显示**设备名称优先、型号回退**
- 同时连接时可设置**优先 USB / 优先 Wi‑Fi / 自动**
- ADB 服务端口可选 `5037`（默认）或 `5038` / `5039` 备用端口
- 型号、Android 版本、分辨率、IP、电量、存储、序列号；电池 `i` 查看健康、温度、电压与电量计
- 设备信息约 6 秒刷新；USB 短暂重枚举时保留上次选中的设备
- 无线连接：配对码 `adb pair`、`adb connect`、`tcpip 5555`
- 保存无线设备并自动重连；刷新、断开、重启 ADB
- 连接向导显示“当前连接”，USB / 无线设备均可一键**连接或断开**；USB 断开只结束应用会话，物理数据线保持连接，可随时重连
- 连接前检测手机是否解锁：锁屏、息屏或无法确认状态时拒绝连接；手动连接、自动选择与无线 `adb connect` 均适用

### 文件

- 浏览 `/sdcard`，隐藏文件开关，面包屑导航
- 上传（选择/拖拽）、下载、导出、Quick Look
- 重命名、新建文件夹、删除（文件/目录）
- 直接安装 APK

### 应用

- 用户应用 / 系统应用切换、搜索
- 启动、强制停止、卸载、导出 APK
- 包名、版本、安装位置与图标

### 投屏

- scrcpy 视频通道（H.264），VideoToolbox 解码，CALayer 渲染；不受 `screenrecord` 180 秒限制
- 点击、拖动映射触控；点击按物理屏幕坐标换算，避开 scrcpy 虚拟显示，桌面图标可正常打开
- Mac 键盘输入映射 Android 按键/文本；设置中可录制自定义键位
- 鼠标控制：左键点击/拖动触控，右键返回，中键打开多任务；右键、中键动作和滚轮正反向均可在设置中修改
- 内置中文 / emoji 输入框：通过控制通道写入并粘贴到手机焦点输入框
- 画质与码率可调，修改后只重启画面，音频不断流；投屏可横竖屏切换并自动适配分辨率
- **设备音频转发**：48 kHz 立体声 16-bit PCM，`AVAudioSourceNode` 按硬件时钟拉流，界面带电平指示
- 截图、全屏与 **Mini 紧凑窗口**（只保留投屏画面，鼠标移入时浮出控制条）、断流自动重连（最多 5 次）
- 横竖屏优先跟随手机：自动旋转/陀螺仪或前台 App 的 `requestedOrientation` 决定方向；全屏不再强制手机横屏。手机锁定方向时可用工具栏临时旋转（8 秒后自动交还，手机改变方向设置时立即交还）
- 停止投屏、退出全屏或退出应用时解除临时方向锁定并恢复手机原旋转设置，避免分辨率残留和视频 App 全屏失效
- 投屏成功 3 秒后检测手机屏幕并自动执行一次关闭；也可随时手动恢复或再次熄屏。物理熄屏使用视频控制通道 `powerMode=Off`，画面与触控继续
- 适配 720×1600、1080×2400、1440×3200 等竖屏设备

### 剪贴板

- Mac → 手机：ASCII 走 `input text`；中文与 emoji 走 scrcpy 控制通道 `SET_CLIPBOARD` + `PASTE`
- 手机 → Mac：控制通道每秒读取剪贴板，**自动同步到系统剪贴板**，绕过 Android 10+ 后台读取限制
- 链接识别并在手机打开；本地历史

### 设置

- 连接优先级（USB / Wi‑Fi / 自动）、ADB 默认与备用端口
- 手机剪贴板自动同步开关、下载目录、隐藏文件策略、`.DS_Store` 清理
- 投屏画质/码率、**投屏时自动关闭手机屏幕（关闭则保持常亮）**、**手动物理熄屏**、**音频转发开关**、**可录制键盘映射**、**鼠标按键映射与滚轮方向**、无线自动重连
- 视频/音频管线诊断、ADB 版本、架构、一键重启 ADB

## 音频转发说明

投屏启动时若开启“转发手机播放声音到 Mac”，应用会：

1. 将内置 `scrcpy-server.jar` 推送到 `/data/local/tmp/androidconnection-server.jar`
2. 以 `audio=true video=false audio_codec=raw tunnel_forward=true` 启动服务端
3. 通过唯一的 `scid` + `adb forward` 建立本地音频 socket
4. 读取 48 kHz / 双声道 / 16-bit PCM，转换为 Float32 并交给 `AVAudioEngine`

注意事项：

- 需要 **Android 13 或更高版本**（系统播放捕获限制）
- 默认使用 `ROUTE_FLAG_LOOP_BACK`，转发时手机扬声器静音，声音从 Mac 输出
- 静音期间不产生 PCM 数据，属于正常现象
- 音频与视频相互独立：音频失败不会中断画面，界面会显示具体状态
- 使用 `AVAudioSourceNode` 按输出硬件时钟拉取环形缓冲，避免 `scheduleBuffer` 队列突发导致加速
- 修改码率/画质只重启视频通道，音频通道保持连接，不会出现 1–2 秒无声
- 音画同步以低延迟为目标，未做专业级时钟对齐



## 构建

只需要 Command Line Tools：

```bash
./Tools/build_app.sh
```

脚本执行：

1. `swift build -c release --arch arm64 --arch x86_64`
2. 组装 `build/AndroidConnection.app`
3. 复制内置 `adb` 与 `scrcpy-server.jar`
4. 生成图标、ad-hoc 签名

检查产物：

```bash
lipo -archs build/AndroidConnection.app/Contents/MacOS/AndroidConnection
# x86_64 arm64
```

开发运行：

```bash
swift build -c release
open build/AndroidConnection.app
```

> 本机仅有 Command Line Tools，`@State` 宏插件不可用；界面状态统一使用
> `ObservableObject` + `@StateObject` / `@EnvironmentObject`。

## 连接手机

### USB

1. 手机开启「开发者选项 → USB 调试」
2. 数据线连接 Mac，允许调试授权
3. 启动应用，设备自动出现
4. 解锁手机，在「连接设备」中点击“连接”；锁屏或息屏状态会被拒绝

> 断开 USB 设备只结束投屏、文件、应用等应用内会话，数据线仍保持连接；列表中的设备会保留“连接”按钮，解锁后可一键重连。断开后自动重连暂停，直到再次手动连接。

```bash
./Vendor/adb devices -l
```

### 无线（Android 11+）

1. 手机与 Mac 在同一 Wi-Fi
2. 手机「无线调试 → 使用配对码配对设备」，记录 IP、端口、6 位码
3. 应用「连接设备 → 无线」填入并配对
4. 后续可直接连接 `IP:5555`；连接时同样要求手机已解锁

也可先 USB 连接，使用“开启无线调试”（`adb tcpip 5555`），拔线后按 IP 连接。

### ADB 端口

默认 `5037`。可在「设置 → 连接与 ADB」切换到 `5038` / `5039`，切换时应用会重启自己的 adb server 并刷新设备。

一个 USB 设备同一时刻只能被一个 adb server 持有。若 `5037` 已被 Android Studio、scrcpy 等程序占用，请先退出对方，或将本应用切到备用端口后再连接。

环境变量仍可用于首次启动覆盖（仅在尚未保存端口设置时作为默认值）：

```bash
ANDROIDCONNECTION_ADB_PORT=5038 open build/AndroidConnection.app
```

## 使用提示

- **连接**：连接前请先解锁手机；锁屏/息屏时应用会拒绝连接并提示。连接向导顶部的“断开”只停止应用会话，USB 物理链路仍保留
- **文件**：拖拽上传；下载保存到设置目录；Quick Look 通过临时下载实现
- **应用**：导出 APK 拉取 `pm path` 的 base.apk
- **投屏**：使用内置 scrcpy 服务端，无需手动授权屏幕录制；修改画质/码率只重启画面通道
- **中文输入**：投屏页底部输入框或剪贴板页输入文本，点击发送后会粘贴到手机当前焦点输入框
- **剪贴板**：手机复制的内容会自动出现在 Mac 剪贴板；可在设置关闭自动同步
- **音频**：首次开启需要约 1 秒建立通道；手机需 Android 13+。USB 与无线均支持音频转发；USB 下请直连 Mac 端口，避免经过不稳定 Hub。
- **护屏息屏**：自动模式把亮度设为 0（部分 Xiaomi 会钳制到 2）；底部“关闭手机屏幕”按钮通过视频控制通道发送 `SET_SCREEN_POWER_MODE=OFF`，`SurfaceFlinger powerMode=Off` 时画面仍继续，但部分机型可能同时停止音频采集，停止投屏会恢复显示电源并唤醒。USB 会临时延长 `screen_off_timeout`、开启 `stayon usb`；停止投屏后恢复原值。
- **日志**：`~/Library/Logs/AndroidConnection/androidconnection.log`

界面自检（无需屏幕录制权限，应用渲染自身窗口）：

```bash
open -n build/AndroidConnection.app --args --snapshot /tmp/androidconnection-ui.png
```

音频链路自检（可选设备序列号）：

```bash
open -n build/AndroidConnection.app --args --audio-test 192.168.10.11:5555
```

控制通道 / Unicode 剪贴板自检：

```bash
open -n build/AndroidConnection.app --args --control-test 192.168.10.11:5555
```

## 架构

```
Sources/AndroidConnection/
├── App/            应用入口、AppModel
├── Models/         AndroidDevice、DeviceDetails、FileItem、AndroidApp
├── Stores/         DeviceStore / FilesStore / AppsStore / ClipboardStore / SettingsStore
├── Mirror/         MirrorSession、AudioForwarder、H264StreamDecoder、MirrorPlayerView
├── Support/        ADB、ADBStream、ScrcpyControl、RemotePath、AppLog、QuickLook
└── Views/          Root / Dashboard / Files / Apps / Mirror / Clipboard / Settings / Connect
```

关键实现：

- `ADB.swift`：`Process` 封装内置 adb，统一超时、端口、输出解析；`ADBStream` 处理长驻 stdout
- `H264StreamDecoder.swift`：Annex-B SPS/PPS → `VTDecompressionSession` → `CVPixelBuffer`
- `ScrcpyVideo.swift`：`video=true control=true` 的 scrcpy 服务端；`send_stream_meta=false` 输出 Annex-B H.264
- `MirrorSession.swift`：画面/音频独立启停，切码率只重启画面；手动旋转仅在数秒内临时覆盖方向，手机改变自动旋转/方向设置或超时后立即交还；`fixed-to-user-rotation` 只在临时旋转和退出竖屏校正期间短暂启用并必定解除；停止/退出时恢复竖屏并刷新分辨率
- `AudioForwarder.swift`：scrcpy 服务端 raw PCM + `adb forward` + AVAudioEngine
- `ScrcpyControl.swift`：独立 control-only scrcpy 服务端；`GET_CLIPBOARD` / `SET_CLIPBOARD`，UTF‑8 中文与 emoji
- 输入注入：`adb shell input tap/swipe/keyevent/text`；Unicode 文本走控制通道粘贴
- `DeviceStore.swift`：轮询、设备名缓存、选择保持、空列表限流 `adb start-server`

## 已验证

（Android 17 / SDK 37，1440×3200）：

- USB 与 Wi-Fi ADB 均识别；
- 文件列表：`/sdcard/` 
- 应用列表：用户应用
- 投屏：324×720 竖屏 / 720×324 横屏；scrcpy 视频通道解码 500+ 帧无错误
- 自动护屏：亮度降到 0 后画面与触控继续；手动物理熄屏已确认 `SurfaceFlinger powerMode=Off`，但该机型可能停止音频采集，默认不作为自动模式
- 音频：源测试音与 Mac 录制峰值同为 440 Hz（录制 8.0 秒对应 8.4 秒文件，含尾部缓冲），确认 1× 速度
- 音频：3 秒捕获 565,248 字节 PCM（约 188 KB/s），RMS 1909；应用内最大电平 0.1734
- 控制通道：`SET/GET_CLIPBOARD` 往返中文与 emoji 成功；粘贴“中文输入😀测试”到系统设置搜索框成功
- 连接优先级：USB + Wi‑Fi 同时在线时，优先 Wi‑Fi 选中 `192.168.0.11:5555`，优先 USB 选中 `
- 备用端口：`5038` adb server 启动成功并识别 USB 设备
- 通用二进制：`x86_64 arm64`，x86_64 切片经 Rosetta 启动并渲染界面
- 窗口 1180×780，可见；“快速终止”已禁用，可稳定驻留

## 已知限制

- 未实现 Finder 侧边栏挂载（需要 File Provider 扩展或 macFUSE）
- 不支持多指手势；仅单指触控与基础按键
- Unicode 文本通过“设置手机剪贴板 + 粘贴”实现，会覆盖手机原剪贴板
- 若手机输入框不支持粘贴，中文/emoji 只能留在手机剪贴板，需手动长按粘贴
- 自动护屏不是物理断电：面板保持唤醒但亮度很低，以保证画面、触控和 USB ADB 可用
- 部分系统界面禁止截屏/录屏（DRM、支付、安全界面）
- DRM/安全界面投屏黑屏（系统限制）
- 仅 ad-hoc 签名，未公证、无自动更新

## 故障排查

**`adb devices` 为空**

```bash
./Vendor/adb kill-server
./Vendor/adb start-server
./Vendor/adb devices -l
```

- 换数据线、直连 USB 口，避开无源 Hub
- 解锁手机，撤销并重新授权 USB 调试
- 退出其它占用 adb 的程序（Android Studio、scrcpy 等）
- 检查 USB 枚举：

```bash
system_profiler SPUSBDataType | grep -i -A4 xiaomi
```

**设备反复掉线**

- 使用数据线直连 Mac，避免劣质线/供电不足 Hub
- 关闭手机省电限制，保持解锁
- 可改用无线 ADB：`adb tcpip 5555` + `adb connect IP:5555`

**无线连不上**

- 确认同一子网：`ipconfig getifaddr en0`
- 关闭路由器 AP 隔离；确认 IP 未变化
- Android 11+ 必须先 `adb pair` 再 `adb connect`
- 端口冲突时 `adb usb` 后重新 `adb tcpip 5555`

**音频没有声音**

- 确认 Android 13+
- 确认投屏页面“音频”按钮为开启状态，并查看状态文字
- 播放一段音乐再测试（静音时不产生 PCM）
- 查看日志中的 `audio start`、`audio first samples`、`audio read ended`
- 若提示“音频通道已断开”，关闭再开启音频开关重试

**投屏黑屏/花屏**

- DRM、支付、安全界面无法录制
- 降低画质或码率
- 确认 scrcpy 服务端可用：

```bash
adb shell CLASSPATH=/data/local/tmp/androidconnection-server.jar app_process / com.genymobile.scrcpy.Server 5.0.1 video=true audio=false
```

**Gatekeeper 拦截**

应用为 ad-hoc 签名、未公证：右键 → 打开，或：

```bash
xattr -dr com.apple.quarantine build/AndroidConnection.app
```

## 隐私

设备数据仅通过本地 ADB 传输，不上传云端、不需要账号。日志仅写入
`~/Library/Logs/AndroidConnection/androidconnection.log`。

## 第三方组件

- Android platform-tools `adb`（Apache License 2.0）
- scrcpy-server（Apache License 2.0），用于设备音频捕获与剪贴板/文本控制
- 应用图标由 `Tools/make_icon.swift` 本地绘制

版权归属：本软件及相关材料的著作权归上述版权所有者所有，受著作权法及相关国际条约保护。
 授权类型：本软件以开源方式发布，允许在遵守下列条件的前提下自由使用、修改、再分发、商业化应用等。具体条款以所选许可证文本为准。
 署名与来源：再分发或使用本作品时，应保留原作者署名及本声明文本；不得隐瞒出处、伪造出处或篡改署名。
 衍生作品：对本软件所作的修改、改编、二次开发形成的衍生作品，其版权归原作者与衍生作者共同享有，需按照相应许可证的要求进行披露与遵循。
 免责声明与责任限制：对因使用本软件所产生的直接或间接后果，版权所有者不承担法律责任，且不对适用性、完整性、可靠性作出保证。
 第三方组件：如本项目中包含第三方开源组件，须在相应位置标注来源、许可证及版本，并遵循该等许可证的要求。
