# 开发与版本管理

## 目录

| 路径 | 内容 |
| --- | --- |
| `native/` | AppKit 窗口、聊天、钥匙串、MiniMax 播放、sherpa 唤醒和 Apple 转写 |
| `native-mcp/` | 官方 MCP Swift SDK 0.12.1、任务连接封装与事件驱动 stdio；通过独立 Swift 库衔接现有原生构建 |
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

需 Apple 芯片、macOS 14+ 和 Swift 6.1 及以上的 Xcode 工具链。构建要求本机有效的 Apple 签名证书；多证书时通过 `BLUEFATFISH_SIGN_IDENTITY` 选择。保持证书与 bundle identifier 稳定，避免更新后失去钥匙串身份。证书、私钥和签名配置不提交。

电脑操作使用 `npm run native:check-desktop -- --live-agent --hold-ui`。脚本创建独立配置和一份公开纯文本文档，原生检查先核对默认关闭、配置冲突、只读／受限 Agent 与工具目录，不请求系统权限、不调用模型。窗口停在「电脑操作」；需用户确认启用并授予辅助功能与屏幕录制权限，再通过系统文本编辑打开输出的公开文档。检查者确认准备完成后，在该次输出目录创建 `start-desktop-live`，真实模型仅通过桌面工具更改审阅人、保存并回读；Node 独立核对文件字节、工具范围、模型计量与生产配置。`finish-desktop-ui` 结束窗口验收，`stop-desktop-check` 停止当前检查。应用确已终止后可用 `--resume <原输出目录>` 继续同一真实任务，不替换原始要求或请求回执。普通检查不带 `--live-agent`，仅证明权限入口和配置边界，不代表实际桌面操作已验收。

构建脚本先构建 `native-mcp` 动态库，再构建原有 Swift 5 AppKit 入口及语音桥接，部署目标保持 macOS 14。Swift Package 使用原生构建后端以保留可直接链接的模块路径；产物包含 SDK、System、Logging、EventSource 的许可证。包内不携带 Node；用户配置的 stdio 服务使用本机运行环境。依赖升级时一并更新并核对 `Package.resolved`。

MCP 相关改动使用 `npm run native:check-mcp -- --live-agent`：先显式在本机安装官方 `@modelcontextprotocol/server-filesystem@2.2.0`（默认检查位置为 `~/Library/Caches/bluefatfish-mcp-real`，可用 `BLUEFATFISH_MCP_CHECK_SERVER` 指定入口）。检查使用独立配置、实际仓库公开素材、真实官方文件服务、公开 DeepWiki HTTP 服务和已保存模型；Node 独立核对生成的 JSON、实际图片大小与 SHA-256。`-- --live-agent --hold-ui` 可保留检查窗口供原生交互验收；不调用麦克风或 TTS。该命令会产生实际 HTTP／模型调用，不能当作离线单元测试。

可加 `--output-limit 2048` 仅调整独立验收配置的回复上限；报告同时记录实际与原有上限，不改生产配置。使用不同预算的验收必须明确标注，不能当作日常 512 上限已通过的证据。MCP schema 通过模型的实际工具定义提供；参数直接绑定到任务会话，避免让模型在另一层 JSON 中重复编码文件内容。

Hooks 相关改动使用 `npm run native:check-hooks -- --live-agent`，使用独立配置、实际仓库公开素材、真实隔离命令及保存的模型预算。模型实际尝试被禁止的写入、询问审阅人、生成报告，并在结束 Hook 要求下补做文件核对；Node 独立检查实际文件大小、SHA-256 与报告。检查同时覆盖两种审批拒绝格式、改写参数后的审批、拒绝输入／答复、读取私有目录与联网限制、配置／资源变化、超时和进程取消。`-- --live-agent --hold-ui` 保留原生管理与任务窗口供检查；报告和配置副本放在本地 evidence，不提交个人数据。

同一命令不加 `--live-agent` 时不调用模型，`hook-config-report.json` 另外记录实际 Exec 参数、带特殊字符的可执行路径、Bash、工具／参数筛选、环境与 Header 的钥匙串事务、本机 HTTP 文件哈希及父子进程清理。HTTP 服务实时读取原始来源文件；记录白名单允许、缺失／拒绝变量、非法控制字符与真实哈希不匹配，不以预制模型回复代替。Node 独立核对实际 argv、环境回执、HTTP 请求及生产九份文件哈希。真实模型模式的生命周期处理器也使用 Exec、env 和条件筛选，原有写入审批与输入拦截继续生效。

环境值的遮蔽在协议判断后进行，不能改变 `block` 或 `false` 的实际含义；向工具参数回传受保护值会停止。HTTP 沿用旧版钥匙串账户绑定，命令凭据另绑定程序、Shell／args 与配置位置；修改目标不能复用原凭据。配置格式有误时仍可打开已遮蔽的原文修复。PowerShell 路径有安装诊断，但当前相关实际执行验收使用 Bash，不代表已验证 PowerShell。

HTTP／模型处理器使用 `npm run native:check-hook-services`：启动实际本机 HTTP 规则服务，服务会读取实际输入和报告核对，而非返回预制模型响应。保存的模型执行主任务，并分别完成单轮内容筛查和只读工具校验；报告包含各自真实用量、子任务与父事件引用，Node 独立回读最终 JSON。检查凭据存储与地址绑定、重定向、无效响应、不重放、断开连接及只读工具边界。`-- --hold-ui` 保留服务与窗口；只需重看现有记录时，可用 `open -n <app> --args --check <已有目录> --hook-service-check --hook-service-ui-only`，不会重新调用模型或启动服务。

模型校验取消可在独立验收目录运行 `open -n <app> --args --check <已有目录> --hook-service-check --hook-service-cancel-only`：使用已保存模型与原预算，收到真实输出后调用校验任务「停止」所用的同一入口，核对子任务、所属 Hook 与活动执行清理，结果写入 `hook-service-cancel-report.json`。这会调用一次真实模型；不用于生产配置，也不作为纯界面检查重复执行。

后台 Hooks 使用 `npm run native:check-async-hooks`：30 项相关检查运行实际命令进程组、计算输入哈希的本机 HTTP 服务，并回读真实运行记录；不调用模型。加 `-- --live-agent` 使用原有模型与预算，完成两阶段素材报告、独立 `prompt`／只读 `agent` 校验、实际退出码 2 唤醒，以及后台运行期间的新要求，共 41 项并由 Node 独立核对文件。两次报告写入都必须经过原有审批。检查隔离目录、作用域、重复触发、恢复、取消、超时、配置变更和输入／转录清理；不把本机 HTTP 证据算成公网服务覆盖。

加 `--hold-ui` 可观察实际后台进度与日志；真实模型模式先在 `ui-background-live` 阶段等待目录中的 `release-background-ui`，最终在 `ui-ready` 等待 `finish-ui`。非模型模式的界面辅助命令实际运行 180 秒，超过后按真实超时处理，不能把事后记录当成运行中观察。日志窗口应在保持打开时随真实状态与耗时更新。验收只复制公开素材，生产设置、历史、原任务、自动化／模型／MCP／Hooks 配置九项均做前后哈希比对。

`npm run prepare:portrait` 从仓库内原图与已保存的透明度引导离线重建素材，不调用生成服务。旧模型处理脚本需要被忽略的历史原件，不能视为全新克隆后的默认流程。

## 只验证本次改动的风险

| 改动 | 可选检查 |
| --- | --- |
| Markdown／Wiki 阅读 | `npm run native:check-markdown -- --candidate-app <签名候选.app>`；复制当前项目实际 README、开发文档与本地图片，在独立目录核对排版、章节／源码导航、文件边界、草稿与保存；此入口不调用模型，需补实际窗口记录。 |
| 用户／工作区知识库 | `npm run native:check-knowledge`；实际文件副本、范围限制、检索、版本保留、恢复及系统协调下载。原生界面创建“离线语音依赖”并导入本项目实际 `vendor/sherpa-onnx/manifest.json`，下载到所选位置，回读字节；无工作区 Ask 任务用已保存模型／预算核对版本与库哈希。观察后写入 `knowledge-download-origin.json`、`knowledge-ui-acceptance.json` 与 `finish-knowledge-ui`。支持 `--prepare-only` 和 `--resume <实际目录>`，保留原任务及失败记录 |
| 项目知识卡片 | `npm run native:check-knowledge-cards -- --prepare-only` 固定真实项目模块与日常数据保护记录；随后 `--resume <实际目录>` 打开同一独立资料目录。真实窗口完成生成、自动更新、英文、编辑及项目导入导出后写入 `cards-ui-acceptance.json` 与 `finish-cards-ui`。30份单任务／90份整轮回执包含失败记录；未通过时保留原任务，不能清空或提高模型预算 |
| 知识卡片原生服务 | 在同一记录目录运行 `npm run native:check-knowledge-cards -- --resume <实际目录> --services-only --service-binary <已按项目身份签名的可执行文件>`。可加 `--context-source <已有真实任务JSON>` 检查多轮用户消息顺序；固定快照与工作区保护哈希分别比对。此入口不初始化WebKit，不调用模型，不验收窗口；可加 `--search-source <已有真实生成任务JSON>` 核对大检索结果。完整窗口流程可用 `--candidate-app <严格签名候选.app>`，避免替换日常应用，并拒绝与仍在运行的真实生成共用资料目录 |
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
| 问答／计划终端与无工作区执行 | `npm run native:check-terminal`；实际 macOS 命令、项目只读限制及任务目录持久化。使用已保存模型与预算，在原生界面选择问答、发送“当前磁盘内存多少”并批准真实终端；观察后写入 `terminal-ui-acceptance.json` 与 `finish-terminal-ui`。支持 `--prepare-only` 及 `--resume <实际目录>`，保留原失败任务和请求计量；不修改日常记录 |
| Git 改动来源、逐文件暂存及可撤销恢复 | `npm run native:check-git-review -- --hold-ui`；真实本机 Git 仓库、索引、提交、分支与系统废纸篓，独立回读文件和检查点；不调用模型。界面观察后写入输出目录的 `finish-ui` 结束保持 |
| 暂存版本提交、并排差异与来源统计 | `npm run native:check-git-review-flow`；实际暂存／工作区分层、选定文件提交、原索引字节、Hook、签名失败、修订变化、二进制、行号与长行布局。加 `-- --live-agent --hold-ui` 保持已保存模型预算跑真实审批，并在原生窗口完成暂存提交与推送到独立本机裸仓库；完成后写入 `finish-ui`。全程不提交或推送用户项目 |
| 工作树管理、回收与恢复 | `npm run native:check-worktrees`；独立真实 Git 仓库核对文件／索引字节、实际 GC 后暂存对象、忽略及未跟踪内容、链接、任务归档、锁定、项目变化、原分支及恢复分支。加 `-- --live-agent` 使用已保存预算执行真实模型检查、回收、恢复和报告回读；加 `--hold-ui` 后在实际窗口完成一次回收／恢复，再写入输出目录的 `finish-ui`。不清理用户项目 |
| 工作树起点、修改预览与任务执行 | `npm run native:check-worktree-creation`；独立真实仓库验证所选分支、带入后的未暂存内容、原始索引、冲突、过期预览及 Hook 范围。加 `-- --live-agent` 使用已保存模型与预算，实际创建后在新工作树任务读写并回读；加 `--hold-ui` 从输入区创建分支 `ui-from-release`，以 release 为起点并带入修改，检查后写入输出目录的 `finish-ui` |
| 工作树保留设置与实际计时回收 | `npm run native:check-worktree-retention`；独立真实仓库、真实等待与文件修改，核对默认关闭、归档范围、当前／固定／锁定任务、实际长 Git 操作、双实例锁、配置冲突、完整备份及 GC 后恢复，不改写时间戳。加 `-- --live-agent` 验证真实模型等待答复时保留、完成后的报告随备份回收；加 `--hold-ui` 从全局设置恢复报告指定的工作树并关闭自动回收，再写入输出目录的 `finish-ui` |
| 命令与 MCP 的本轮文件记录 | `npm run native:check-file-changes`；实际命令、官方文件 MCP、独立 Git 索引与文件字节，核对新增、删除、改名两侧、大文件、链接、权限、外部编辑隔断、停止、超时及实际终止应用后的恢复。使用已有 `~/Library/Caches/bluefatfish-mcp-real` 官方文件服务，不模拟模型响应。加 `-- --live-agent` 用已保存预算执行真实销售核算与 MCP 备注任务；加 `--hold-ui` 审阅本轮差异，从记录窗口撤回报告指定的 MCP 备注，再写入输出目录的 `finish-ui`。已通过实际文件检查的待审批验收任务，可加 `--resume /输出目录` 继续原任务，保留中断记录及原请求计量 |
| Git 推送与提交并推送 | `npm run native:check-git-push`；实际 TCP Git 服务与独立裸仓库，核对提交快照、远端变化、精确引用更新、项目／接收端 Hook、取消和超时结果。加 `-- --live-agent --probe-ssh --hold-ui` 使用已保存模型预算跑审批与远端回读、沿用现有 SSH 身份只读连接 GitHub，并保留窗口验收提交并推送；不向项目 GitHub 远端发布。界面完成后写入输出目录 `finish-ui` |
| 项目检索与 Repo Wiki | `npm run native:check-index`；实际 SQLite、公开退款规则和已配置真实模型，核对增量更新、业务回答、Wiki 生成、跨任务引用及读写范围 |
| 文档解析与附件存储 | `npm run native:check-documents`；需要测试用 Python 的 python-docx 1.2.0、openpyxl 3.1.5、python-pptx 1.0.2；可用 `BLUEFATFISH_DOCUMENT_PYTHON` 指定解释器。这些库仅创建/回读公开测试文件，不进入应用，也不验证 AI 对话效果 |
| 附件连续对话后端 | 在上述检查后加 `-- --live-attachments`，使用已配置真实模型读取三类 Office 文件、执行中追加、回答提问并保护未发送草稿；视觉和原生输入界面单独验收 |
| 附件界面与真实视觉 | 文档检查加 `-- --attachment-ui --live-visuals`；原生导入、切换任务、窄窗口、QuickLook/文字预览，以及真实模型读取两张不同布局的无字图形。仅公开夹具，不开启麦克风或 TTS；当前模型须已声明视觉能力 |
| 原生浏览器 | `npm run native:check-browser`；真实公开 Qoder 文档导航、本项目实际 Vite 开发预览、控件状态、任务隔离、页面引用冲突、停止和正常/窄窗口。测试配置放系统临时目录，再归档到 `evidence/agent/`，避免新签名应用因外置盘权限阻塞启动。不会调用模型 |
| 浏览器真实 Agent | 上述检查加 `-- --live-agent`；使用应用已保存的真实模型，在逐次确认模式下打开本机预览、点击棋盘背景、重新读取并独立检查实际开关状态。没有模型配置时明确失败；不使用模拟回复，不开启麦克风或 TTS |
| 多标签与公开表单 Agent | 浏览器检查加 `-- --extended --live-agent`；按应用已保存的上下文与回复预算，使用真实模型填写、选择并提交 Calculator.net 公开计算器演示数字，独立核算网站结果，再切换保留的本机预览标签。原生部分同时检查跨标签引用、关闭、网站数据共享与任务隔离；不登录或提交其他表单 |
| 浏览器截图与标注视觉 | 浏览器检查加 `-- --visual --live-agent`；需解锁并配置视觉模型，保持已保存预算。真实模型读取本项目实际页面截图，再分别识别同一页面上两处不同红框按钮；答案独立取自实际 DOM。核对本应用窗口裁切、其他窗口排除、录屏权限前后状态、来源/分支保留、未发送草稿隔离和正常/窄标注窗口 |
| 独立图片/PDF 视觉 | 构建后以 `--check <新建临时目录> --live-agent --live-visuals` 启动应用，不加 `--document-check`，可直接复用两张无字 PNG/PDF 的真实模型验收，不依赖 Office 夹具库；此项使用单独的 32768／2048 验证预算，不代表浏览器默认小预算 |
| Skills 与命令 | `npm run native:check-extensions` 检查实际 ZIP 导入、目录与任务边界、命令展开、启停持久化、编辑冲突、资源分支和原生界面；加 `-- --live-agent` 使用保存的真实模型与原有预算，调用导入脚本为本项目现有角色图片、来源文件、样式文件生成清单，再用自定义命令生成交接。Node 独立核对实际文件大小和 SHA256；不联网、不改原素材、不调用麦克风或 TTS |
| README／Git 管理 | 检查相对链接、暂存内容与 `git diff --cached --check` 即可 |

原生浏览器检查使用系统 WebKit；网页角色的自动化检查使用本机 Google Chrome。脚本输出写入被忽略的 `evidence/`。不默认运行全部历史脚本或 GitHub Actions。

页面截图在 macOS 14.4 及以上使用 `SCShareableContent.currentProcess`，匹配本进程拥有的具体浏览器窗口，再通过单窗口 `SCScreenshotManager` 捕获与裁切。模型只提供任务内标签编号，不能选择其他应用或窗口。软件快照仅用于 macOS 14.0—14.3，并向用户和模型说明 GPU 内容可能缺失。系统锁屏会暂停网页绘制，截图前后均检查锁屏状态，失败时不保存或发送空白图。

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


角色扩展与逐工具权限验证：`npm run native:check-agent-scopes -- --live-agent`。复用 `native:check-mcp` 已安装的官方 filesystem 服务；仅用独立临时项目的公开素材和应用中保存的模型配置，凭据不落到报告。`--hold-ui` 保留实际配置窗口；不传 `--live-agent` 时仅运行原生范围和实际 MCP/文件检查。`--facts-source <真实旧任务JSON>` 用于检查历史记录整理后实际协议、数值和完整哈希的保留；不得提供模拟模型回复。

本机团队与执行者选择验证：`npm run native:check-agent-teams -- --live-agent --hold-ui`。独立临时项目使用公开的 source.json 与 character.png，真实主任务委派团队，负责人让两个成员分别读取来源与执行文件校验，再写出并回读实际报告；Node 独立核对五字段、输入文件哈希和生产配置哈希。不传 `--live-agent` 只运行与本次修改相关的原生配置、任务草稿/附件和权限范围检查；不产生替代模型回复。`--hold-ui` 保留团队窗口供实际操作验收。

本机自动化验证：`npm run native:check-automations -- --live-agent --hold-ui`。原生部分覆盖时区和夏令时、真实单次定时触发与暂停、文件锁、项目失效失败、权限、系统实际防休眠断言及分页记录。真实模型由计划启动所选 Agent，再在同一任务中执行第二轮报告，独立核对计数和来源字段；待审批时尝试重复运行与分支，不允许覆盖原运行记录。使用独立配置和公开素材，不使用替代模型回复，不申请或更改系统通知权限。仅本机检查时省略 `--live-agent`。

MCP 资源与提示词验证：`npm run native:check-mcp-content -- --live-agent --hold-ui`。需要先从官方 npm 注册表将 `@modelcontextprotocol/server-everything@2.2.1` 安装到 `~/Library/Caches/bluefatfish-mcp-everything-real`。检查实际服务器的静态文档、URI 模板、带参数提示词、目录与订阅通知和图片内容；Node 独立核对安装包的文档字节与报告。真实模型使用保存的配置、原有上下文与输出预算，读取用户选用的提示词附件，经审批读取 MCP 文档、写入并回读五字段报告，再描述实际工具图片。默认不传 `--live-agent` 只做相关原生与真实 MCP 进程检查，不返回替代模型回复。配置与公开输入哈希需保持一致。

文档流程已有相同生产代码的实际完成证据时，可加 `--image-only` 仅复验图片模型流程，仍执行相关实际 MCP 原生检查。此模式不产生文档通过声明，需保留并单独核对先前真实文档结果及源码差异。

知识卡片本轮追加额度仅在用户明确同意后启用：原目录保存 `cards-budget-authorization.json`，运行时加 `--cards-extra-requests 30`，总上限120次；不清空此前任务、失败或计量。可用 `--finish-source <已有实际任务JSON>` 检查已由模型提交完成证据的任务恢复；该记录须包含真实成功工具事件与调用ID，原生发布仍重新校验源码、分支和版本。
