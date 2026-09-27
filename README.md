# 键盘桥 · Keyboard Bridge

Mac 内置键盘 → 接收器 → Windows USB HID 键盘。当前是可编译的 macOS 原型，含本机模拟接收器；尚无 ESP32 固件，也未经真实游戏/硬件验证。

## 构建与打开

需要 macOS 13 或更新版本、Swift 6 工具链（Xcode 或 Command Line Tools）和 Python 3（用于模拟器及测试）。

```sh
git clone https://github.com/ZiPinG23/keyboard-bridge.git
cd keyboard-bridge
```

```sh
./scripts/build-app.sh
open dist/KeyboardBridge.app
```

应用常驻菜单栏（⌨ Mac / ⌨ Windows），不出现在 Dock。首次启用转发时，在系统设置 → 隐私与安全性 → 辅助功能中授权 KeyboardBridge；如授权后仍失败，退出并重新打开。开发版本采用临时签名，重新构建可能需要重新授权。

## 板子到货前验证

1. 在终端运行 `python3 scripts/mock_receiver.py`，输入临时密钥（至少 16 字符）。模拟器只监听本机，不注入系统输入。
2. 打开应用，地址保留 `127.0.0.1`，端口 `45832`，输入同一密钥，点击“连接 / 重新连接”。
3. 等待显示“接收器已响应”，点击“切换”。之后使用 **Control + Option + Command + K** 在 Mac 和接收器间切换。
4. 转发期间键盘输入在模拟器终端以 HID 编码显示，不应打进本地编辑器。鼠标/触控板仍控制 Mac。快捷键只在首次成功安装键盘监听后生效。
5. 关闭模拟器，应用应在约 500 ms 后返回 Mac。模拟器若超过 300 ms 未收到状态，会报告释放全部按键。

## 当前范围与限制

- 普通字母、数字、标点、方向键、F1–F12，以及 Control/Shift/Option/Command；物理键位发送到 Windows，由 Windows 输入法解释。
- Option → Alt；Command → Windows；左右修饰键暂统一为左侧。尚无自定义映射界面。
- Fn、媒体键、Touch ID 不支持；macOS 安全输入及部分系统快捷键可能限制捕获。F 键可能需要系统设置为标准功能键。
- 切换前松开普通按键；已按住的普通键不会补发。切换快捷键的修饰键可能先短暂传到接收器。正式版需完善切换状态处理。
- 每个包携带完整键盘状态、会话 ID、递增序号；50 ms 心跳补偿单次丢包。短促按键仍可能因 UDP 丢包而丢失，正式固件联调需增加边沿可靠交付。
- 原型使用 HMAC-SHA256 认证，**不加密按键内容，不具备完整的抗重放握手**。当前只建议本机模拟验证，不用于输入密码或在不可信网络使用。正式局域网版本需升级到加密配对协议。
- 不保存配对密钥；只保存主机和端口。不记录按键到文件，模拟器会在终端显示 HID 编码。
- 未实现真实 USB 输出，不承诺游戏兼容性或延迟指标。

## 验证

`./scripts/test.sh` 检查 HID 核心映射及数据认证/篡改检测。模拟器与 App 的实际按键捕获，需要用户授予辅助功能权限后手动验证。

## 开发计划

- 完善切换状态处理、左右修饰键和可配置映射。
- 实现加密配对、抗重放握手及可靠按键传输。
- 开发 ESP32-S3 USB HID 接收器固件。
- 验证真实硬件上的长按、多键输入、断线恢复及延迟。

欢迎通过 GitHub Issues 报告问题或讨论功能，通过 Pull Request 提交改进。提交前请运行 `./scripts/test.sh` 和 `./scripts/build-app.sh`。

## 许可证

本项目采用 [MIT License](LICENSE)。
