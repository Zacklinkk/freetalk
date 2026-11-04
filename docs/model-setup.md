# 本地模型安装

设置页与首次引导使用同一安装流程。按钮只在主动点击后联网；正常语音推理进程设置 `HF_HUB_OFFLINE=1` 和 `TRANSFORMERS_OFFLINE=1`。

## 安装流程

1. 检查已有 Python 是否满足固定的核心依赖版本；符合则复用。
2. 否则从 [uv 官方 release](https://github.com/astral-sh/uv/releases/tag/0.13.7) 下载固定的 Apple Silicon 安装工具，校验 SHA-256，然后准备独立的 Python 3.11.14。
3. 从 PyPI 安装 [固定版本与哈希的依赖](../setup/requirements.txt)，只接受二进制 wheel。文件位于应用自己的运行目录，不改系统 Python、Shell 配置或 PATH，无需 sudo。
4. 从 Hugging Face 的固定 revision 下载 [清单](../setup/catalog.json) 中的文件。检查已有文件时同时验证大小与 SHA-256；完整复用不会重新联网下载权重。
5. 大文件写入 `.partial`，中断后可续传。服务端必须确认匹配的字节范围；如果忽略 Range，就重新写入而不拼接错误内容。
6. 每个文件完整验证后才原子替换。所选模型全部成功后才原子更新 `config.json`；失败或取消保留原配置。最后重载并预热模型。

原始模型资源：

| 模型 | 固定 revision | 清单文件字节数 |
| --- | --- | ---: |
| [ASR 0.6B 8bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | `89e96d92ba34aca20b3e29fb10cc284097d1219f` | 1,010,771,234 |
| [整理 4B 4bit](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) | `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` | 2,278,969,697 |

表格只计算推理文件，不包含模型说明页、下载缓存和 Python 依赖。模型按各自 Apache 2.0 许可证使用，freetalk 的 MIT 许可不改变它们的许可。

## 目录与故障处理

默认目录：`~/Library/Application Support/freetalk/`。

- `runtime/managed-v1/`：安装工具、独立 Python、虚拟环境与依赖缓存。
- `runtime/models/<模型>/<revision>/`：固定版本的模型文件。
- `downloads/`：运行环境安装工具压缩包。
- `setup.log`：依赖安装输出或错误。分享前检查本机路径等信息。
- `config.json`：实际运行的 Python 和模型路径，以及分段参数。

网络错误时点击重试；磁盘不足时释放空间后再试。取消不会删除已经下载的有效片段。文件损坏时校验会拒绝使用或补齐下载。页面的「文件已就绪」是轻量文件大小检查，点击校验才计算完整 SHA-256。

开始下载后暂停新的录音请求，避免配置切换。已有推理进程保留到安装成功；失败不会主动卸载原来的模型。关闭设置窗口不会取消下载，退出应用会取消。

如果 `config.json` 损坏，安装器会停止并保留文件，避免覆盖原有配置。先备份并修复这个文件。早期版本迁移复用原来的模型路径，因此旧版运行目录仍可能被引用。

## 更新依赖或模型清单

需要有意识地更新固定版本、校验值和验证记录，不自动追踪 `main`。依赖清单的生成命令：

```sh
MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile setup/requirements.in \
  --python-version 3.11 --python-platform aarch64-apple-darwin \
  --generate-hashes --output-file setup/requirements.txt --no-header
```

改变版本后，重新验证空目录安装、取消/续传、模型实际加载与整理效果。安装器使用 [uv 的独立 Python 支持](https://docs.astral.sh/uv/guides/install-python/)；仅版本锁定不能代替依赖安全审查。
