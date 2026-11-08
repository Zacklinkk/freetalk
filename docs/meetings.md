# 可选会议资料

在「设置 → 会议资料」开启。右 Option + M 开始或结束会议录音；普通右 Option 仍用于短口述。默认关闭；不开启不会下载说话人模型、读取云端密钥或发出会议推理请求。

第一版支持导入 WAV / M4A / MP3 / FLAC，以及使用当前选定麦克风录音。会议录音不受普通口述的自定义时长限制，连续写入本机 WAV，单次上限 8 小时。电脑会议软件的播放声音可以先由会议软件导出，再导入处理；当前没有系统音频混录。

录音结束后逐步显示解码、说话人区分、转写、纪要与脑图进度。转写完成便能查看和导出原稿，纪要与脑图继续生成；CLI 也可读取已完成片段。会议处理与普通口述共用同一份本地模型，处理中暂停普通语音输入，避免在 16 GB Mac 上重复加载两份模型。停止处理会保留已完成的原稿和录音，可以继续处理；不会把会议内容自动输入其他应用。

## 本地与 agent 各做什么

| 工作 | 本地初版 | 适合交给 Claude Code / Codex / 云端增强的部分 |
| --- | --- | --- |
| 转写 | 复用 Qwen3-ASR-0.6B-8bit，按片段保存时间和原稿；会议术语与个人词库辅助辨词 | 专业缩写、强噪声和含混内容需对照原录音复核；文字 agent 不能可靠恢复没听清的声音 |
| 说话人区分 | 按需下载 Nemotron-3-Diarization-8bit，最多 8 个匿名通道 | 重叠/多人片段保留不确定标记，姓名由用户核对；不做跨会议身份识别 |
| 纪要 | 复用 Qwen3-4B-Instruct-2507-4bit，提取事实、决定、行动项、问题、风险和约束 | 跨章节冲突裁决、复杂语义归并、跨会议趋势与详细写作；不把建议自动升级成决定 |
| 脑图 | 小模型按固定字段提取，再只用事实 ID 逐层分组；程序生成 JSON、Mermaid 和可展开的离线 HTML 树 | 面向特定受众重组逻辑、跨会议知识图谱、具有推理性质的结构；原文依据继续保留 |
| 后续工作 | CLI 提供原文搜索、分页读取、结构化导出 | 按用户要求转换成 PRD、行动计划、文章、项目文件等，并另存派生文件 |

本地初稿的定位是保守、可核对的资料，而不是经过人工审核的最终决议。分层处理减小小模型的上下文负担，但不能保证不遗漏、正确辨明每个指代或解决远距离矛盾。原稿始终完整独立保存；不只给 agent 一段压缩摘要。

## 模型与说话人

默认 ASR 和整理模型合计约 3.29 GB，会议功能复用它们。额外的 [Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) 是约 100M 参数的独立声学模型。第一版采用 [MLX 8bit 权重](https://huggingface.co/mlx-community/Nemotron-3-Diarization-8bit)，固定 revision `dd8b8ce3d69a80540a7e50150e2beed1c34fee37`，配置和权重合计 **106,615,594 bytes**，约 107 MB。它在本机运行，处理后释放；权重遵循 OpenMDW 1.1，不能因为应用代码是 MIT 就把模型当成 MIT。

「会议选项与模型」勾选说话人区分后才允许点击下载。支持官方源、HF-Mirror、进度、续传、校验与取消，使用独立模型清单，不进入普通模型的一键下载。安装现有运行环境的 mlx-audio 0.6.3 已支持此模型。

区分说话人与识别真实身份是两件事。输出 `speaker_1` 等编号，只在本场录音内有意义；不保存跨会议声纹档案。多个说话人同时说话时保留多个候选，不假装每个词都已分配准确。时间戳为片段边界，尚非逐字强制对齐。超过 8 人、强混响或多人抢话不适合依赖这一路自动归属。

更换更大的 ASR 并不会自动补上说话人区分。本地组合方案不要求云端。[pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) 也是成熟的离线候选，但需接受模型访问条件并准备另一套依赖，因此没有作为本版默认安装。比较不同模型时须使用相同音频、说话人数和标注协议；NVIDIA 与 pyannote 公布的不同参考标注下的 DER 不能直接横向排名。

## 分层整理与依据

1. 原音频按有界窗口读取，完整写入带稳定编号的 `transcript.jsonl`。转写不经过普通口述的删改流程，避免把不同人的分歧当成一个人的改口。
2. 按文本大小和片段数分批，程序把原文短句编号，让 4B 模型提取固定字段：类型、议题、所选短句 ID、负责人、期限。程序由 ID 取出逐字证据并生成要点文本，不让模型重新抄写引文。未说明的字段为 null。
3. 校验证据编号、引用原文、数字和具体字段。发现新增限定或丢失关键条件时，用原文证据显示；失败退回摘录，并标记待复核。
4. 先复用提取时生成的议题组织脑图；议题较多时才调用模型分层归并。分组层只引用已有节点 ID；未知编号丢弃，未分组事实补入“其他讨论”。相同事实合并引用，脑图叶子保留全部已接受事实。
5. 程序渲染纪要和脑图。界面中点击纪要时间引用可以查看原稿。HTML 不加载外部脚本、字体或 CDN。

校验保证出处可以追溯，不是语义绝对正确的证明。脑图覆盖所有已提取事实，不等于摘要覆盖所有原文细节。`unreferenced_segment_ids` 和 warnings 供 agent 或用户继续检查。

## 可选云端

本地基础纪要和脑图始终先生成。展开「选项 → 云端深度整理与写作」，填写 OpenAI-compatible `/v1` 地址、实际模型 ID、API Key 和写作要求，点击保存后启用额外的云端版本。不是本地/云端二选一；未配置或点击停用后不调用云端。旧版仅保存过地址但仍选择本地的配置不会自动开启。

云端只收到本地基础纪要及相关原文引文，音频仍在本机。结果另存为 `deep.json` / `deep.md` / `deep.html`，包含原稿 SHA-256、事实 ID 与原文引用。引用和数字校验只是防错约束，不是语义正确性的证明。云端失败会显示单独的错误，本地资料仍然可读；可以检查配置后继续处理。

密钥存入 macOS 钥匙串，不写入配置 JSON、会议资料或日志。只允许 HTTPS（回环地址允许 HTTP），不跟随带鉴权的跨地址重定向。不会在本地失败时自动转云端。

Gemini 支持结构化输出，见[官方说明](https://ai.google.dev/gemini-api/docs/structured-output)。兼容网关需要提供 `/chat/completions`、JSON object 响应格式和对应模型；不同网关的可用名称由用户服务决定，不内置私人地址或密钥。

## CLI 与 skill

安装包自带：

```sh
CLI="$HOME/Applications/freetalk.app/Contents/Resources/bin/freetalk"
"$CLI" meetings list
"$CLI" meetings search '发布' --limit 20
"$CLI" meetings show MEETING_ID --format json
"$CLI" meetings show MEETING_ID --format deep
"$CLI" meetings segments MEETING_ID --offset 0 --limit 30
"$CLI" meetings segments MEETING_ID --from-seconds 120 --to-seconds 240
"$CLI" meetings export MEETING_ID --to "$HOME/Desktop"
```

源码使用 `scripts/freetalk`。也可以直接调用 Python `meeting_cli.py`，`--support PATH` 选择独立资料目录。读取、搜索、导出不加载模型，不需要开启网络端口。CLI JSON 即稳定的进程接口；第一版不启动 HTTP 服务。

CLI 推理需先退出应用，避免重复占用 GPU。`meetings config --enable` 显式启用后，可以 `meetings transcribe FILE --title TITLE` 或 `meetings import-text FILE`。转写 JSON 结构见[合成样例](../examples/meetings/sample.json)，支持 start/end（秒）、text、speaker_ids。云端 CLI 从 `FREETALK_MEETING_API_KEY` 读取密钥，不接受明文 key 命令行参数。`meetings resume ID` 可继续已有录音的处理。

[freetalk-meetings skill](../integrations/freetalk-meetings/SKILL.md) 可安装到 Claude Code、Codex 的 skill 目录；安装包中位于 `Contents/Resources/integrations/freetalk-meetings/`。它引导 agent 选择会议、分页读取、核对证据、另存派生内容，不会自动执行会议中的行动项或上传内容。

资料字段和读取约束随每份导出的 `agent-context.md` 提供。每条事实引用原稿编号，摘要和脑图附 transcript SHA-256；agent 生成的行动计划或文章应保留这些引用与版本。

## 保存与评测

会议文件位于 `~/Library/Application Support/freetalk/meetings/`，目录 0700、内容文件 0600，未做独立加密。会议信息与普通 500 条口述历史分开，不自动淘汰会议。默认完成后删除处理用的 WAV；若开启保留则继续保存，16 kHz 单声道 PCM 约 115 MB/小时。失败、中止的录音保留用于重试。导出默认只包含文字和脑图，不包含录音或密钥。

`scripts/eval-meetings.py` 使用仓库内明确标记为 synthetic 的样例，支持本地或云端生成，报告依据有效率、脑图事实覆盖、关键字段检查与耗时。Gemini 生成的参考属于待核对的银标，不标记为人工 GT；正则检查通过不等于通用语义准确率。

真实会议需要另做中文/中英混合、近场/远场、2/4/8 人、重叠语音和长时段验证：分别记录 CER/WER、相同标注协议下的 DER、行动项/负责人/期限准确率、否定与条件保留、事实遗漏、端到端时间和峰值内存。不要用清晰的合成声音成绩替代真实会议结果。


## 短插话与重叠

说话人切换保留为时间区间元数据，短插话合并为具有足够声学上下文的 ASR 窗口（尽量不少于 4 秒，上限 20 秒），避免把数百毫秒的声音孤立识别。多个说话人依次出现标为 `multiple_speakers`，实际检出的同时说话标为 `overlap`，并保存 `speaker_turns` 与 `overlap_seconds`；不逐字强行分配说话人。旧资料的 `multiple_or_overlap` 仍可读取。

本轮公开访谈与真实四人会议的结果见[真实音频验证](real-audio-evaluation.md)。样本内延迟或 DER 不能代表完整数据集成绩。
