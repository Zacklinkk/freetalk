# Contributing

欢迎提交功能改进与可复现的问题。请说明 macOS 版本、芯片、麦克风连接方式、输入应用和整理模式；不要提交密码、私人文稿、音频、词库或完整诊断目录。

优先用自己编写的合成句子说明「识别原稿 → 期望输出 → 实际输出」。区分 ASR 听错、规则处理、小模型编辑和跨应用插入四个阶段，并说明是否真的调用了整理模型。

提交代码前运行 `PYTHON=.venv/bin/python bash scripts/test.sh` 和 `bash scripts/build.sh`。界面或录音路径的改动还需手工验证，注明已测硬件和未覆盖的情况。请为涉及原意、条件、否定、数量、字面引用的编辑变更新增有意义的回归样例。

改整理提示词或规则前后，都用真实模型跑一遍整理测试集 `evals/cleanup-cases.json`（51 条：用户确认过的 22 条，加上每类失败的同源变体），新结果没有变差才提交：

```bash
# 先退出 freetalk，16 GB 内存同时加载两份模型会大量换页
python scripts/eval-cleanup.py --model <整理模型目录> --output before.json
# 改完后
python scripts/eval-cleanup.py --model <整理模型目录> --output after.json --baseline before.json
```

以前通过的条目变成不通过，或通过总数下降，脚本以非零状态退出并列出变差的条目。`tests/test_cleanup_eval.py` 在 CI 里用记录的模型回复回放同一批条目（正确的回复必须得到期望文字，模型给过的错误回复必须被拒绝），不需要模型。新增条目时写明 `group`（失败类型），同源变体用 `variant_of` 指向原条目。

快捷键、粘贴、改字学习、窗口文字识别、会议录音和夜间整理这些应用内流程，可以用端到端检查在本机跑一遍：`bash scripts/build-e2e.sh` 构建带测试钩子的 `build/freetalk-e2e.app`（只用于测试，不要安装或发布），再运行 `python3 -I scripts/e2e/run.py`。它需要 freetalk 已有辅助功能、输入监控、麦克风和屏幕录制权限，以及 BlackHole 2ch 虚拟声卡（测试语音经它送进 freetalk，房间里不会放声）。检查期间会退出正在运行的 freetalk、把文本编辑放到最前面并按快捷键，结束后恢复设置并重新打开 freetalk；用 `--wait-idle 600` 可以等电脑 10 分钟没人用时再开始。测试用一个临时数据目录和编造的历史，不读取、不发送你的转写记录。

不要加入远程推理、遥测或自动发送行为作为默认选项。模型下载必须固定可信来源、版本和哈希，并保留失败后的原配置。改字候选不能升级为无条件全文替换。
