# 开发协议 v1（仅原型）

UDP 45832。每个数据报为 JSON：`{"payload":"base64(JSON bytes)","mac":"base64(HMAC-SHA256)"}`。
HMAC 密钥为配对文本的 UTF-8 字节，认证原始 payload 字节，禁止重新编码 JSON 后验签。

payload 字段：version=1、session（每次连接生成 UUID）、sequence（从 1 递增）、enabled、modifiers（USB HID modifier byte）、keys（去重排序的 USB HID usage 数组）。enabled=false 时必须释放所有键。

模拟接收器验签后，按 session 和 sequence 丢弃旧包，再原样回显数据报作为 ACK。Mac 仅接受本次 session 且大于最后 ACK、且不超过已发送序号的有效回包。发包每次状态改变立即执行，并每 50 ms 心跳重发全状态；接收器 300 ms 无有效数据则释放，Mac 500 ms 无新 ACK 则停止转发。

这是功能验证协议，不能直接作为生产协议：没有内容加密；ACK 未做消息类型隔离；新会话缺乏挑战应答和持久化抗重放；UDP 可能丢失短促按键边沿。硬件开发阶段须升级为认证加密、会话握手、明确 ACK 类型、可靠边沿/状态恢复，再验证丢包、重排、重启及输入到 USB 报告的延迟。

固件还需决定 NKRO 报告描述符，处理 USB 未枚举、主机休眠和断线释放。模拟器打印任意数量 usage 不代表实际 USB 同时按键能力已验证。
