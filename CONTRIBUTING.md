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

不要加入远程推理、遥测或自动发送行为作为默认选项。模型下载必须固定可信来源、版本和哈希，并保留失败后的原配置。改字候选不能升级为无条件全文替换。
