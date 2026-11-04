# freetalk

<img src="docs/assets/mark.svg" width="96" height="96" alt="freetalk 音量条图标" />

**说得自然，写得清楚。**

在 Mac 的输入框放好光标，轻按右 Option，说完再按一次。freetalk 在本机识别语音、整理口述，然后把文字填回草稿，由你检查和发送。

Local speech-to-text and faithful dictation cleanup for Apple Silicon Macs. No account, API key, or cloud inference.

> 实验性版本。优先面向中文与中英混合口述；整理与专名识别仍可能出错，请检查输出。

## 能做什么

- 跨应用语音输入，光标附近显示音量、录音状态和目标应用；结束提示 5 秒后消失。
- 清理明确的口水词和口吃，处理本次录音里的改口与撤回；尽量保留原意、细节、条件和否定。
- 按语境规范数字、合并已知英文缩写，默认少换行，明确列举时分点。
- 个人词库，以及从可靠的局部改字中学习候选拼写；学习后可撤销。不会永久强制替换某个错词。
- 跟随系统默认麦克风，也可以指定设备。右 Option 开始/停止，Esc 取消。
- 保存最近 500 条文字历史，超出后删除最旧记录；不保存录音。
- 首次使用引导：准备模型 → 逐项授权 → 真实试说。原稿与整理结果并排对应，试说不写入其他应用或历史。
- 在应用内下载本地模型和独立运行环境，支持进度、取消、续传、重试与文件校验。

## 安装

需要 **Apple Silicon、macOS 14 或更新版本**。建议至少 16 GB 统一内存和 8 GB 可用磁盘空间。首次下载需要访问 Hugging Face、GitHub 和 PyPI；准备好后推理离线运行。

当前提供源码构建，需要 Xcode Command Line Tools：

```sh
xcode-select --install # 已安装时跳过
git clone https://github.com/Zacklinkk/freetalk.git
cd freetalk
bash scripts/build.sh
bash scripts/install.sh
open "$HOME/Applications/freetalk.app"
```

首次打开会显示引导：

1. 点击「下载推荐模型与运行环境」。无需预先安装 Python、MLX 或其他语音软件。
2. 按系统提示允许麦克风；跨应用输入需要辅助功能权限，右 Option 需要输入监控权限。认证由本人完成。
3. 在引导里试说一句，检查识别原稿、整理结果和实际耗时。也可跳过试说。
4. 到目标应用点击输入框，再使用右 Option。freetalk 不会按 Enter 或自动发送消息。

引导随时可从菜单重新打开。「设置 → 本地模型」提供各模型单独下载、校验与重试。如果暂不开放跨应用权限，允许麦克风后也可以在引导中试说。

默认构建采用本地 ad-hoc 签名，未做 Apple 公证；更新后 macOS 可能要求重新关联原有权限。开发者可通过 `FREETALK_SIGNING_IDENTITY` 使用自己的稳定签名身份。应用不修改系统隐私数据库，也不要求关闭系统安全功能。

更新源码后，先从菜单退出 freetalk，再执行：

```sh
git pull --ff-only
bash scripts/update.sh
open "$HOME/Applications/freetalk.app"
```

更新脚本备份旧应用。早期 Local Voice 用户的小型配置、词库和历史会复制到新目录，既有模型路径继续复用；原数据保留。不要删除仍被配置引用的旧运行目录。

## 本地模型

| 用途 | 默认模型 | 权重形式 | 下载量 |
| --- | --- | --- | --- |
| 语音识别 | [Qwen3-ASR-0.6B](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | MLX 8bit | 约 1.01 GB |
| 文字整理 | [Qwen3-4B-Instruct-2507](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) | MLX 4bit | 约 2.28 GB |

两者都在本机通过 MLX 运行。下载量合计约 3.29 GB，不含独立 Python 和依赖，也不等于实际内存占用。模型单独遵循 Apache 2.0 许可，仓库不包含模型权重。

模型版本和逐文件 SHA-256 固定在 [模型清单](setup/catalog.json)。下载完成且校验成功后才更新配置；取消或失败保留原配置和可继续下载的片段。Python 依赖也固定版本与哈希。详见 [模型安装说明](docs/model-setup.md)。

默认「自动整理」会对短句使用快速规则，对改口、疑似重复、填充词或多句口述调用小模型。也可选择每次调用或仅使用规则。历史和试说页显示实际是否调用模型。模型常驻，录音中分段提前识别；一次录音最多 90 秒。速度受硬件、音频长度和整理复杂度影响，不承诺固定延迟。

## 隐私与输入安全

音频仅在内存中处理。运行时不调用云端推理、不监听网络端口。需要的上下文仅来自开始录音时的当前输入框，最多开头 500 字和光标附近 1,000 字，可在设置中关闭。

插入前会再次确认应用、输入框、原有草稿与选区。如果用户已经切换位置、修改草稿，或应用无法提供足够信息，结果留在历史中供复制，不会盲目输入。粘贴使用临时剪贴板并尽量恢复之前的内容。

历史和词库位于 `~/Library/Application Support/freetalk/`，使用本机文件权限保护，未做独立加密。改字学习只观察本次成功输入后的同一输入框，最多 90 秒；离开输入框或开始下一次录音就停止。它提供辨词提示，不训练权重，也不按错词做无条件替换。详见 [数据与学习说明](docs/privacy-and-learning.md)。

## 开发与验证

```sh
# 轻量测试无需下载模型
python3 -m venv .venv
.venv/bin/python -m pip install pypinyin==0.55.0
PYTHON=.venv/bin/python bash scripts/test.sh
bash scripts/build.sh
```

测试覆盖编辑约束、数字语境、词库、下载续传与失败恢复，以及 macOS 侧的输入目标身份、快捷键、历史容量、学习撤销和旧版迁移。公共测试使用合成样例；不包含个人录音、转写历史、词库或第三方逆向产物。模型效果和物理麦克风需要另行实测，单元测试通过不等于所有应用都能自动输入。

下载模型后，可退出应用，用配置中的 Python 运行 `scripts/smoke-models.py --config <config.json> --audio <sample.wav>`。WAV 需为 16 kHz、单声道、16 位 PCM；该检查显示实际原稿、结果与耗时，不写入历史。请使用非私人样例，不要把真实口述报告上传到 Issue。

架构与边界见 [设计说明](docs/architecture.md)，引导与手工验收见 [首次使用说明](docs/onboarding.md)，本次实测与限制见 [验证记录](docs/validation.md)。欢迎提交合成复现样例，见 [贡献说明](CONTRIBUTING.md)。源码采用 [MIT License](LICENSE)。
