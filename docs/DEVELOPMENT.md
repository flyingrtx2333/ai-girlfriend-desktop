# 开发与版本管理

## 目录

| 路径 | 内容 |
| --- | --- |
| `native/` | AppKit 窗口、聊天、钥匙串、MiniMax 播放、sherpa 唤醒和 Apple 转写 |
| `src/main.js` | 场景、点击分区、动作调度、原生桥接和帧率管理 |
| `src/portrait.js`、`src/portrait-tail.js` | 原画网格变形、分部位弹簧和独立鲸尾 |
| `src/motions.js`、`src/idle.js` | 互动轨道、表情轨道和 AIRI 待机采样 |
| `native/ChatViews.swift`、`native/ControlWindow.swift` | 原生侧栏、消息行、输入框和设置 |
| `native/SpeechAnimation.swift`、`src/speech.js` | 在内存解码音频、分析开合和频谱、按播放时钟插值口型 |
| `native/ScreenCompanion.swift` | 闲置调度、单帧窗口截图、相似画面过滤、取消与免打扰 |
| `public/portraits/`、`public/audio/`、`public/animations/` | 当前原生应用运行素材、来源和许可 |
| `public/models/whale-maid-v2/` | 网页「立体」模式仍引用的模型和贴图；不打包进原生应用 |
| `design/references/`、`design/portrait19/` | 重建当前原画贴图需要的原图、透明度引导和提示词 |
| `vendor/sherpa-onnx/manifest.json` | 固定依赖来源和哈希；下载缓存和二进制不提交 |
| `scripts/` | 构建、素材准备及按需验证 |
| `docs/verification/` | 当前基线的精选验证记录 |

旧三维候选、VRM 导出、付费服务任务、账单与完整测试产物保留在本地 `assets/`、`reference-assets/`、`design/model-*`、`evidence/`、`归档/` 等目录，不纳入首次提交。原 README 完整保存在本地 `归档/README-before-git-0.6.0.md`；它包含历史实验和账单，不是当前功能说明。

## 本地开发

```sh
npm ci
npm run dev
```

原生构建与打开：

```sh
npm run native:build
npm run native:open
```

需 Apple 芯片、macOS 14+ 和 Xcode 工具链。构建要求本机有效的 Apple 签名证书；多证书时通过 `BLUEFATFISH_SIGN_IDENTITY` 选择。保持证书与 bundle identifier 稳定，避免更新后失去钥匙串身份。证书、私钥和签名配置不提交。

`npm run prepare:portrait` 从仓库内原图与已保存的透明度引导离线重建素材，不调用生成服务。旧模型处理脚本需要被忽略的历史原件，不能视为全新克隆后的默认流程。

## 只验证本次改动的风险

| 改动 | 可选检查 |
| --- | --- |
| 互动和原画动画 | 启动开发服务器后运行 `npm run check:companion` |
| 原生编译或打包 | `npm run native:build` |
| 屏幕陪伴 | `npm run native:check-screen`；真实抓屏与在线服务需显式加 `-- --installed --capture-fixture --live-vision` |
| 原生拖动、释放和回稳 | 构建后运行 `npm run native:check-drag`，需解锁且窗口可见 |
| 唤醒与转写 | 构建后运行 `npm run native:check-voice`，需系统权限；不调用在线对话或 TTS |
| 停止录音与超时 | `npm run native:check-stop -- --installed`，真实本机语音指令与麦克风释放，不调用在线模型 |
| 真实麦克风与断流恢复 | 构建后运行 `npm run native:check-microphone`；需解锁和已有权限，不保存音频或转写，不调用在线服务 |
| 气泡与唤醒提示音 | 构建后运行 `npm run native:check-feedback`；额外传入 `-- --live-tts` 才使用已保存的 MiniMax 配置发出一次短语音请求 |
| 聊天排版、停顿与口型 | 构建后运行 `npm run native:check-conversation`；独立示例配置，真实本机转写与已有 MiniMax 音频，无在线调用 |
| 对话传输协议 | `npm run native:check-service`；本地协议检查，不代表模型效果 |
| 钥匙串读写和版本更新 | `npm run native:check-keychain`；使用独立测试凭据 |
| Agent Git 状态、审阅、提交和工作树 | `npm run native:check-git`；独立公开仓库和已配置真实模型，实际核对提交、其他暂存内容、Hook 与工作树，不访问生产仓库 |
| 项目检索与 Repo Wiki | `npm run native:check-index`；实际 SQLite、公开退款规则和已配置真实模型，核对增量更新、业务回答、Wiki 生成、跨任务引用及读写范围 |
| 文档解析与附件存储 | `npm run native:check-documents`；需要测试用 Python 的 python-docx 1.2.0、openpyxl 3.1.5、python-pptx 1.0.2；可用 `BLUEFATFISH_DOCUMENT_PYTHON` 指定解释器。这些库仅创建/回读公开测试文件，不进入应用，也不验证 AI 对话效果 |
| 附件连续对话后端 | 在上述检查后加 `-- --live-attachments`，使用已配置真实模型读取三类 Office 文件、执行中追加、回答提问并保护未发送草稿；视觉和原生输入界面单独验收 |
| 附件界面与真实视觉 | 文档检查加 `-- --attachment-ui --live-visuals`；原生导入、切换任务、窄窗口、QuickLook/文字预览，以及真实模型读取两张不同布局的无字图形。仅公开夹具，不开启麦克风或 TTS；当前模型须已声明视觉能力 |
| README／Git 管理 | 检查相对链接、暂存内容与 `git diff --cached --check` 即可 |

浏览器检查使用本机 Google Chrome，运行前需安装该浏览器。脚本输出写入被忽略的 `evidence/`。不默认运行全部历史脚本或 GitHub Actions。

## v0.6.0 的实际验证范围

- [原画与互动](verification/companion.json)：14.2 秒实际 WebGL 动画、原生释放协议夹具和 GPU 位移读回；按 204×288 逻辑像素计算，扣除头／腰移动后，尾鳍待机摆幅约 6.4 像素、头发约 3.7–4.1 像素。仍是 2 次绘制。
- [原生拖动](verification/native-drag.json)：受控窗口轨迹、延迟接收按下、返回原点仍算拖动、持有、释放和回稳。不是系统鼠标模拟。
- [语音](verification/voice.json)、[关键词](verification/kws.json)：真实中文文件经本机引擎推理；普通说话和近似词不启动完整转写，唤醒加命令触发一次关键词检测和一次转写。不是实时麦克风或在线对话质量验收。
- 在已安装原生应用中，CUA 点击头部、身体分别看到了眯眼歪头与缩肩圆口。CUA 坐标拖动调用未造成窗口位移，不能记录为真实拖拽通过。

这些记录是基线证据，不代表所有设备的持续帧率、耗电量、AI 回答质量或已经达到 AIRI 的精细角色表现。

## v0.6.1 的气泡与声音

[原生反馈记录](verification/feedback.json)验证了短气泡 101×42 点、长句气泡 268×72 点，以及本地提示音播放和结束。一次实际 MiniMax `speech-02-hd`／`female-shaonv` 请求返回 2.88 秒音频，经原生播放器播放并驱动口型。测试使用固定短句，不发送私人聊天历史；这不是实时麦克风、声学回声或完整语音对话验收。

唤醒音由 `scripts/prepare-wake-chime.mjs` 离线合成并随应用打包，没有复制系统提示音。它使用独立播放器，不改动正在进行的转写任务。MiniMax 请求采用[官方同步语音接口](https://platform.minimax.cn/docs/api-reference/speech-t2a-http)。

## 麦克风断流恢复

0.6.1 的现场日志在 19:44:04 记录了 Core Audio 输入转为 Stopped，随后出现引擎配置变化通知；应用没有监听此事件，界面一直保留「聆听中」。重启唤醒后恢复了音频 I/O 线程，用户确认喊「小鲸小鲸」重新有反应。

0.6.2 在原有语音串行队列异步重建采集，符合 Apple 对 [AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange) 的处理要求：不在内部通知回调中同步释放引擎。仅唤醒开启时以低频检查引擎和音频帧；连续三次恢复仍没有输入则停止并报告原因。实际音频帧重置重试次数；关闭、锁屏和休眠会移除观察者并取消监测。

[真实麦克风检查](verification/microphone.json)中，初始收到 21 个音频缓冲，实际停止引擎并发送配置变化通知后恢复到 30 个，再停止引擎而不显式发通知后恢复到 88 个；恢复后最近音频帧分别为 26／98 ms 前。关闭后引擎保持停止。测试只记录计数和电平，不保存声音、转写或调用在线模型。现场问题与重启后用户确认恢复的记录见[故障记录](verification/wake-recovery-case.json)。

## v0.7.0 的界面、语音轮次与口型

用户提供的第二张图作为布局参考，在现有 AppKit 中实现侧栏、白色主区、右侧用户气泡、底部输入框；没有引入 Electron、第二个 WebView 或图片化界面。公开截图只含固定示例对话，私人聊天与参考截图不进入版本库。

旧代码在 0.85 秒静音或识别器 `isFinal` 时收尾。现在由整轮静音时长决定提交，识别器结束一个片段不代表用户说完；本机识别器也可能不发 `isFinal` 就替换前半段文字，代码结合音频分段时间和停顿保留旧片段。默认等待 3 秒，设置可选 2／3／5 秒。测试音频包含「我想问你一件事」与「这个周末去哪里散步比较好」两段，中间 1.8 秒静音，实际转写保留两段并只提交一次。

口型曲线以 20 ms 步长分析音频开合及频带，在 `AVAudioPlayer.currentTime` 的时间线上由渲染端插值。音频在内存中经系统 AudioToolbox 解码，Accelerate 分析，播放期间用 15 Hz 时钟校正替代原来的 30 Hz 音量驱动；无需新模型。它仍是频谱估算的近似口型，不是文本强制对齐或音素识别。

[验证记录](verification/conversation.json)覆盖正常／窄窗口、设置切换、真实本机停顿转写，以及已有 MiniMax 音频的实际播放和 WebGL 口型。完整截图、音频时钟采样及带声音的实播保留在本地 `evidence/edition28/`。记录中的时钟误差只比较原生播放位置与渲染时钟，不能当作声学输出或音素对齐误差。

## v0.7.1 的分类设置

设置使用 AppKit 侧栏、搜索框、开关和可滚动的分组卡片。分类与搜索复用已有控件，保留未保存的输入；不增加 WebView、定时刷新或运行依赖。搜索只筛选设置，不会使模型连接检测状态失效。

`npm run native:check-settings` 使用独立配置检查分类、跨分类搜索、草稿保留和 980×700／780×540 排版，并输出原生截图。[验证记录](verification/settings.json)与公开截图不含用户配置或凭据。该检查不启用麦克风，不调用在线模型或 TTS，也不重复运行上一版语音与口型测试。

## v0.8.0 的屏幕陪伴

使用系统 [SCScreenshotManager 单帧接口](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:))，按前台应用 PID 和窗口层级选择当前窗口；手动从设置触发时观察最近的外部应用窗口。缩略图最长边 1280 像素，JPEG 质量 0.68。截图只在内存中存在；不采集系统音频，也不启动持续视频流。

启用时每 15 秒低成本检查一次截止时间，定时器允许 5 秒合并唤醒；请求间隔至少 60 秒，默认 300 秒。角色交互后至少等待 20 秒，聆听、对话、语音播放、拖动、收起、暂停、锁屏和休眠会阻止观察。外部应用切换会取消尚未完成的观察或模型请求；重试最长退避到 30 分钟。

同一应用的 32×18 缩略采样在本地比较，变化不足时跳过模型请求；仅保留采样和最近三条评论。单帧视觉请求不附带私人聊天历史，提示模型将截图文字视为数据，忽略其中指令，并可返回 `[安静]`。这是一帧图像的近似理解，不代表视频剧情、音频理解或敏感信息识别保证。

`screenState` 驱动观察扫视、循环思考和评论点头。头发、衣服与尾巴继续走现有弹簧，不增加绘制调用。MiniMax 与音频口型复用原路径，主动评论传入 `followUp: false`，避免结束后自动开启续聊转写。系统日志的 `ScreenCompanion` 分类只记阶段、尺寸和计数，不记截图、窗口标题、评论或 Token。

[验证记录](verification/screen-companion.json)包含真实 ScreenCaptureKit 固定窗口截图、已配置视觉模型的实际输出与 MiniMax 实播。固定画面是原生绘制的橙色三节小车、桥、河流、绿山与白云；这些事实没有写入视觉请求。检查专用配置与公开画面允许输出到 `evidence/edition30/`，正常功能不会保存截图。界面窄窗口检查另行复用现有原生设置检查，不重复运行无关语音回归。

## v0.8.1 的停止录音

旧实现只在 `finishSession()` 收尾时匹配停止指令，而背景声会持续刷新 `lastLoud`；原来的 10 秒期限仅覆盖尚未识别文字的情况，有文字后会不断续接片段。即使返回「等待唤醒」，声学关键词检测仍占用麦克风。

停止指令现在在 `receive()` 的局部识别结果上处理，立即取消识别并释放输入引擎；按钮和语音命令都汇入同一个宿主停止方法，关闭已保存的唤醒开关、取消当前回复并过滤迟到事件。输入缓冲路径也检查启用状态。现有低频输入看门狗同时检查整轮 60 秒期限，不因识别器换段而重置；超时草稿保留在原有输入之后。

聆听气泡只在采音时接受按钮点击，其他气泡继续点击穿透；聆听时不设气泡隐藏定时器。Escape 是应用内快捷键，不拦截其他应用的 Escape。

[验证记录](verification/voice-stop.json)使用本机中文语音「小鲸小鲸，请停止录音」，紧接六秒连续噪声，检查在噪声结束前停止且不提交聊天。按钮测试实际启动麦克风并检查引擎、识别器与唤醒模型释放；60 秒上限通过推进期限检查点验证，麦克风仍为真实采集。只记录计数和固定夹具，不保存私人声音或转写，也不重跑屏幕视觉与 TTS 检查。

## Git 约定

`main` 保存能运行的版本，标签用于回到已记录的基线。后续屏幕陪伴可从独立分支开始：

```sh
git switch -c feat/screen-companion
git add <本次修改的文件>
git diff --cached --check
git commit -m "feat: add screen companion reactions"
```

按功能拆提交，文档用 `docs:`，修复用 `fix:`，新增行为用 `feat:`。使用 `git add` 的明确路径，提交前检查 `git diff --cached --stat`，避免把本地记录或下载缓存带入仓库。

`.gitignore` 排除构建、测试输出、环境变量、证书、服务配置与旧模型；当前运行所需的少量二进制素材直接跟踪，不引入 Git LFS 依赖。未配置远程仓库，也未上传任何内容。
