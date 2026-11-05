# 开发与版本管理

## 目录

| 路径 | 内容 |
| --- | --- |
| `native/` | AppKit 窗口、聊天、钥匙串、MiniMax 播放、sherpa 唤醒和 Apple 转写 |
| `src/main.js` | 场景、点击分区、动作调度、原生桥接和帧率管理 |
| `src/portrait.js`、`src/portrait-tail.js` | 原画网格变形、分部位弹簧和独立鲸尾 |
| `src/motions.js`、`src/idle.js` | 互动轨道、表情轨道和 AIRI 待机采样 |
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
| 原生拖动、释放和回稳 | 构建后运行 `npm run native:check-drag`，需解锁且窗口可见 |
| 唤醒与转写 | 构建后运行 `npm run native:check-voice`，需系统权限；不调用在线对话或 TTS |
| 真实麦克风与断流恢复 | 构建后运行 `npm run native:check-microphone`；需解锁和已有权限，不保存音频或转写，不调用在线服务 |
| 气泡与唤醒提示音 | 构建后运行 `npm run native:check-feedback`；额外传入 `-- --live-tts` 才使用已保存的 MiniMax 配置发出一次短语音请求 |
| 对话传输协议 | `npm run native:check-service`；本地协议检查，不代表模型效果 |
| 钥匙串读写和版本更新 | `npm run native:check-keychain`；使用独立测试凭据 |
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
