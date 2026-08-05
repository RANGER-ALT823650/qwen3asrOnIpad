2026-08-05 CST

# 当前：iPad 分屏常驻链路修复

- 已从当前 `codex/qwen-ipad` 分支移除识别完成和录音启动后的两处 `UIApplication.suspend`，模型 App 不再主动退出分屏。
- 停止录音只发 Darwin 通知，不再通过 `qwen3asr://stop` 打开模型 App；分屏中的主 App 原地推理并回传文字。
- 开始录音按 request ID 等待主 App 确认，未确认时先重发一次 Darwin 通知，之后才允许使用 record URL 做冷启动兜底。
- 若结果到达时日记键盘暂时不可见，结果保留在 App Group，等真实键盘重新显示后再插入，避免第二轮文字丢失。
- 前台判断同时接受 `foregroundActive` 和 `foregroundInactive`，适配日记 App 持有键盘焦点时的 iPad 分屏状态。

# 语音键盘冷启动与转写修复摘要

## 改了什么

- 将 Whisper 上下文和转写任务放在主 App 进程中复用，键盘扩展只通过 App Group 与 Darwin 通知交换状态和结果。
- 主 App 冷启动或重新回到前台时会接管 App Group 中仍然有效的录音请求；即使自定义 URL 的 payload 没有交给 SwiftUI scene，也能继续启动录音。
- 移除 iOS 27 真机上会错误命中 `UIScene`、导致扩展 `SIGABRT` 的三参数私有 URL selector；侧载版只保留 ABI 明确的旧 `openURL:`，失败时提示手动打开 App。
- 键盘定时同步共享状态，为启动和识别增加超时恢复，避免扩展重建后永久停在“正在启动/识别中”。
- 修复非零起始 Data 切片导致的 WAV 越界崩溃；当 AVAudioRecorder 没来得及回写 data 长度时，从实际文件尾恢复 PCM。
- 停止录音后先释放 AVAudioRecorder，确保转写读取文件前尽量完成 WAV 头收尾。
- 在加载模型前检测近乎静音的输入，并提示检查麦克风，避免把无音频误判为识别卡死。
- 真机 Metal 推理失败时会重建 CPU context 并对同一录音自动重试一次；最终错误会带上 whisper 返回码，同时保留失败 WAV 供排查。

## 为什么这样实现

第三方键盘扩展不能直接使用麦克风，也不能通过公开 API 可靠地打开主 App。因此录音和模型推理必须由主 App 持有，App Group 状态是跨进程的事实来源；URL 和 Darwin 通知只负责尽快唤醒或提示仍存活的进程。

## 后续可以安全修改

- 键盘提示文案、12 秒启动超时、180 秒识别超时和 120 秒录音上限。
- Whisper 推理参数，例如线程数、语言和分段策略。
- 状态轮询间隔，但不应完全移除轮询，因为扩展重建期间可能丢失 Darwin 通知。

## 修改时需要谨慎

- `openContainingApp` 仍是仅用于开始阶段冷启动的侧载兜底；自动 suspend 已移除，不要重新引入，也不要恢复三参数 `openURL:options:completionHandler:`。
- `AppGroupBridge.RecordStatus`、键盘状态处理和 AppRecordController 必须同步修改。
- 不要把 Whisper 推理重新放回键盘扩展；扩展内存和生命周期不足以稳定承载模型。
- 不要恢复对 Data slice 的零起始下标假设，也不要假定 WAV data chunk 的声明长度一定已回写。

## 假设与限制

- 主 App 与键盘扩展继续共享 `group.project.qwen3asr`。
- iOS 仍可能拒绝键盘私有 URL 桥接；此时只能显示明确错误并让用户手动打开主 App。
- 当前模型推理要求千问3 ASR仍在 iPad 分屏前台；离开分屏时会保留待处理 WAV，并等待 App 回到可见前台。

## 建议的下一步

- 在已启动的 iOS 26.5 模拟器和真机各做一次“强制结束主 App后从键盘开始”的端到端验证。
- 增加 WAV 解析单元测试，覆盖 4096 字节 FLLR/JUNK 头、data 长度为 0、奇数字节和截断文件。
- 为每轮请求增加 request ID，以便未来彻底隔离迟到的跨进程回调。
