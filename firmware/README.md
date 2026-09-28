# ESP32-S3 蓝牙 → USB HID 固件

目标：ESP32-S3 N16R8。使用 16 MB Flash；当前不使用 PSRAM。固件关闭 Wi-Fi，提供 BLE v1 服务和标准 USB HID 6KRO 键盘。

## 构建与刷写

安装 Python 3 和 PlatformIO，然后在仓库根目录运行：

```sh
python3 -m venv .tools
.tools/bin/pip install platformio esptool
.tools/bin/pio run -d firmware
.tools/bin/pio run -d firmware -t upload --upload-port /dev/cu.YOUR_PORT
```

必须通过芯片查询确认目标是 ESP32-S3。串口适配器型号不能单独确定主芯片型号。默认 115200 波特率，部分 FTDI 板在更高波特率时会出现损坏数据。

刷写前可通过 esptool read-flash 备份 Flash。`backups/` 已被 Git 忽略；其中可能包含其他固件的 Wi-Fi 凭据，不应上传。前 2 MiB 备份只覆盖这次启动程序、分区表和应用写入范围，不是完整的 16 MiB 备份。固件启动也会使用 NVS 保存蓝牙绑定。

## 两个 USB 口

- UART/COM：刷写和日志，本身不提供 USB HID 键盘功能。
- 原生 USB/OTG：键盘输出，正常使用接 Windows。首次测试也可以接 Mac 检查枚举，但不要在同一台 Mac 上开启输入转发，以免输入回环。

只连接 UART 时，可以给板子供电并测试 BLE 握手；不能测试 USB 键盘输入。不要以串口可用推断原生 USB 接线已验证。

## 首次配对

1. 启动固件后短按 BOOT，开启 120 秒配对窗口。也可通过本地串口发送字符 `p`，效果相同。
2. 串口以 115200 输出随机生成的六位配对码。该码保存在板端 NVS 中，不在源码里。
3. Mac 应用选择蓝牙模式，扫描并连接 `KeyboardBridge-S3`。允许系统蓝牙权限，在系统配对提示中输入六位码。
4. 固件要求加密、MITM 认证和 bonding，认证完成后保存唯一主人身份。配对成功后关闭配对窗口。断线后可重连同一主人。
5. 板子原生 USB 口移接 Windows 后，在 Mac 应用开启转发，先用记事本测试。

重置主人：固件运行中按住 BOOT 超过 5 秒。清除板端绑定并重启；Mac 上也需忘记应用设备及必要的系统蓝牙配对。不要在通电前一直按 BOOT，否则芯片会进入下载模式。

## 保护与验证范围

- 只接收认证后来自主人连接的 20 字节状态。
- 会话以全释放包开始，拒绝错误版本、旧序号和跨会话数据。
- USB 报告发送成功才确认启用输入；原生 USB 未连接时，只允许禁用状态握手。
- BLE 断开或 300 ms 无合法输入会释放按键并断开连接。
- 首次握手后每 50 ms 心跳；固件不记录具体按键。
- C++ 主机测试覆盖包验证；Swift 测试覆盖发送队列。
- 蓝牙实际认证、USB 枚举、Windows 输出、休眠恢复及延迟仍需逐项实测，构建成功不代表这些全部通过。

依赖版本固定在 `platformio.ini`；Arduino-ESP32、NimBLE-Arduino 和工具链遵循各自的上游许可证，不由本项目 MIT 许可证替代。
