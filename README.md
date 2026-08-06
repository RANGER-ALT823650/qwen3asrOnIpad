# qwen3asrOnIpad

> **Qwen3-ASR 1.7B iOS 端侧语音输入法 —— iPad 分屏邪修版**  
> 100% 纯本地离线大模型 ASR 识别，零隐私泄漏风险，无需局域网或 Mac 服务依赖。

---


## ✨ 核心特性

- **100% 端侧离线**：内置 `Qwen3-ASR-1.7B-MLX-5bit` 完整模型权重，音频编码与文本解码复用本地模型，不上传任何音频，无网络请求。
- **iPad 分屏优雅联动**：针对 iPadOS 优化，主 App 不主动挂起分屏，兼容 `foregroundActive` 和 `foregroundInactive` 焦点切换。
- **无感跨进程通信**：基于 App Group (`group.project.qwen3asr`) 与 Darwin 原生通知机制，免跳应用完成转写。
- **灵活的录音控制**：主 App 内置录音时长选择器（15-50 秒），键盘实时波形进度条同步。
- **完善的容错机制**：内置近乎静音自动检测、超时卡死重置、请求 ID 绑定与离线 WAV 保障机制。

---

## 💡 碎碎念 (The Origin & Technical Journey)

项目最初的目标很简单：**把千问 3 (Qwen3-ASR 1.7B) 这个强大的语音识别大模型塞进 iOS 端侧，做成随叫随到的系统级语音输入法。**

但在实际落地过程中，苹果 iOS 系统底层各种冰冷的限制给开发过程泼了一盆又一盆冷水：

### 1. 键盘扩展（App Extension）的“大逃杀”限制
iOS 的第三方键盘只是一个键盘扩展（Input Method Extension），系统分配给它的内存上限极度苛刻（通常仅为 **50MB ~ 70MB** 左右）。而 Qwen3-ASR 1.7B 哪怕经过 5-bit 量化，模型权重依然有大约 **2.4GB**。如果想在键盘扩展进程里直接加载模型，瞬间就会引发系统级别的 Jetsam 内存溢出强制杀进程（OOM `SIGKILL`）。

### 2. 后台 GPU 与 ANE 的冰封禁界
既然 Extension 跑不下，自然想到让主 App 在后台帮你跑推理。但苹果官方文档与系统机制做出了明确限制：**应用转入后台后，Metal GPU 上下文会被系统挂起或强制销毁，无法在后台持续调用 GPU 算力。**

### 3. 付费开发者账号与 Extension 的尴尬限制
即使购买了付费的 **Apple Developer Program** 并尝试申请 Background Tasks 或相关后台模式权限，键盘扩展本身本质上依然是独立的 Sandbox。想要让 Extension 无缝唤醒后台主 App 并利用 GPU 进行实时推理，在 iOS 的常规权限体系下依然几乎无法实现。

### 4. 纯 CPU + Neural Engine (ANE) 绕过方案可行吗？
社区中也曾有人尝试通过关闭 Metal GPU，仅使用 CPU + Neural Engine (ANE) 来绕过 GPU 的后台挂起限制。但对于 1.7B 参数级别的 Audio Encoder + Text Decoder 结构：
- **CPU 推理**：手机/平板 CPU 的算力在跑 1.7B 解码时延迟极高，发热巨大；
- **ANE 限制**：Apple Neural Engine 对现代 Transformer/LLM 复杂的算子支持极不健全，无法完整承载整个解码流程。

---

## 🥷 终极“邪修”方案：iPad 分屏常驻 (Split View)

在被 iOS 的各种限制打倒之后，本人发现了一个简单粗暴但极其高效的**“邪修”解决办法**——**iPad 分屏常驻 (Split View)**！

### 运行机制：
1. **分屏维持前台生命周期**：在 iPadOS 上，将 `qwen3asrOnIpad` 主 App 与你正在使用的笔记/日记软件（如 Obsidian、Craft、Apple Notes 等）**左右分屏运行**。
2. **解锁 Metal GPU 全额算力**：只要主 App 位于分屏前台（即使焦点在旁边的日记 App 上），系统就会认定其处于前台活跃状态，从而赋予主 App 完整的 Metal GPU 访问权限和充足的内存空间！
3. **App Group + Darwin IPC 极速响应**：
   - 键盘扩展负责拾音、音频预处理与进度条绘制；
   - 停止录音时通过 `CFNotificationCenter` (Darwin Notification) 与 App Group 广播信号；
   - 分屏中的主 App 原地接收信号，直接调用本地 MLX GPU 快速完成 1.7B 模型转写，再把文本精准回传给键盘插入。

---

## 🎯 最佳使用场景：离线拼图式语音日记

这个“邪修”输入法最舒服的使用场景莫过于**语音写日记 / 长文灵感记录**：

> **“说话说一段 ➔ 停顿触发识别转写 ➔ 屏幕自动填入文字 ➔ 组织思路继续说下一段 ➔ 循环往复”**

在 **iPad 数字版（A16 芯片）** 上实测：
- 支持 **15~50 秒** 自由调节单次最长录音时长（默认 32 秒，实测 40 秒也可用）；
- 单轮识别时间应该能控制在5秒以内，勉强够用，非流式输出



## 🛠️ 项目架构说明

```
qwen3asrOnIpad/
├── Shared/                      # App Group 共享通信层 & 音频 IPC 通信
│   ├── AppGroupBridge.swift     # 状态管理、录音时长持久化与 App Group 读写
│   ├── AudioRecorder.swift      # 离线 PCM/WAV 录音与音频流封装
│   └── DarwinNotifications.swift# 跨进程 Darwin 信号广播桥接
├── qwen3asr/                    # 主 App (Host App) - 分屏运行主进程
│   ├── HybridQwen3ASREngine.swift  # Qwen3-ASR MLX-5bit 本地模型推理引擎
│   ├── AppRecordController.swift   # 监听键盘请求、逻辑与推理调度
│   ├── ContentView.swift        # 主界面设置（支持最长录音时长调节）
│   └── qwen3asrApp.swift        # 应用入口与生命周期管理
├── Qwen3ASRKeyboard/            # 键盘扩展 (Keyboard Extension)
│   ├── KeyboardViewController.swift # 系统键盘生命周期与输入挂载
│   ├── KeyboardView.swift       # 键盘录音 UI、波形动画与状态反馈
│   ├── NineKeyInputModel.swift  # 九键输入逻辑与候选词推导
│   ├── NineKeyLexicon.swift     # 本地离线九键拼音词库匹配引擎
│   └── Resources/               # 离线词库文件 (pinyin9.lex)
├── qwen3asrTests/               # 核心逻辑与 App Group 通信单元测试
└── ModelAssets/                 # Qwen3-ASR 1.7B 5-bit 本地模型配置
```

---

## 🚀 快速上手与编译配置

1. **环境要求**：
   - macOS 建议使用最新 Xcode；
   - 支持分屏功能 (Split View) 的 iPadOS 设备（建议 A14 / A16 及以上芯片）。
2. **App Group 配置**：
   - 在 Xcode 的 Signing & Capabilities 中，为主 App 和 `Qwen3ASRKeyboard` 扩展配置相同的 App Group ID（默认 `group.project.qwen3asr`）。
3. **部署至 iPad**：
   - 侧载/编译安装到 iPad 上；
   - 打开系统设置 ➔ **通用** ➔ **键盘** ➔ **添加新键盘** ➔ 添加 `qwen3asr` 并开启 **允许完全访问**；
   - 打开主 App 完成模型初始化，随后将其拖至屏幕边缘开启 **分屏 (Split View)**，即可开始享受离线大模型语音转写体验！

---

## 📜 许可证 & 致谢

- 离线模型核心基于开源 [Qwen3-ASR 1.7B MLX-5bit](https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-5bit)。
- 感谢苹果 MLX 框架以及开源社区对端侧 AI 的持续探索。
