# 版本发布与自动更新

## 用户如何更新

0.3.0 首次加入应用内更新。0.2.x 用户需先从本仓库 [Releases](https://github.com/Zacklinkk/freetalk/releases/latest) 手动安装一次。之后打开「设置 → 软件更新」，有新版时侧栏显示「有更新」。应用默认启动时和每天检查，可关闭自动检查并随时手动检查。

点击「下载更新」才开始下载，页面显示百分比和已下载大小；网络未返回总大小时只显示已下载大小。下载时可以取消，连接失败可以重试。完成签名校验后点击「安装并重启」。录音、文字整理、文字插入和模型下载期间此按钮不可用；已准备的更新也会在退出应用后安装，可先点击「取消更新」取消该安装。

应用更新只替换 `.app`，不修改 `~/Library/Application Support/freetalk` 中的模型、配置、历史和词库。因网络或签名校验失败而中止时，继续使用旧版本。GitHub 不可达时，可稍后重试或从同一 Release 手动下载；不自动切换到不受控的更新源。

## 仓库维护者如何发布

修改代码后，需要同时更新 `native/Info.plist`：

- `CFBundleShortVersionString`：例如从 `0.3.0` 改成 `0.3.1`，采用 `主.次.补丁` 格式。
- `CFBundleVersion`：从 `7` 改成 `8`，每次发布严格递增的整数。这是 Sparkle 判断更新的版本号。
- 新建 `docs/releases/0.3.1.md`，说明本次变化。

提交并推送到 `main` 后，GitHub Actions 先执行测试、构建、签名结构检查及隔离应用的真实更新检查。全部通过后，发布任务创建草稿 Release，上传应用 ZIP、签名的 `appcast.xml` 和 `SHA256SUMS`，核对 GitHub 返回的资产大小与 SHA-256，再转为正式发布。已有同版本 Release 时跳过；普通同版本代码提交不会让用户下载未发布的构建。不手工修改已发布的安装包或更新列表，需要修复时发布新版本。

客户端固定使用：

```
https://github.com/Zacklinkk/freetalk/releases/latest/download/appcast.xml
```

ZIP 下载地址固定到具体 Release 标签，不跟随分支源码。测试失败、发布任务失败或仍是草稿时，用户继续看到上一个正式版本。首次发布之前手动检查可能报告找不到更新地址。

本地运行 `python3 scripts/publish-release.py` 只准备签名资产到 `build/releases/v版本号/`；`--publish` 才会上传。发布要求工作区已提交并通过相同检查。不要把未经检查的本地包手动设为 latest。

## 签名与权限

使用固定版本 Sparkle 2.10.1，构建脚本校验官方依赖归档 SHA-256。客户端要求更新列表和安装包通过 Ed25519 签名；只拿到 GitHub 下载地址或修改其 SHA-256 文本不能绕过客户端验证。完整性签名不等于 Apple 公证。

仓库公钥写在 `SUPublicEDKey`。原始私钥保存在维护者 macOS 登录钥匙串的 `io.github.zacklinkk.freetalk` 账户下，CI 使用仓库 Actions Secret `FREETALK_SPARKLE_PRIVATE_KEY`。密钥不进入 Git、Release、命令行参数或日志。私钥应另做安全备份；更换密钥需要遵循 [Sparkle 密钥迁移说明](https://sparkle-project.org/documentation/) 后发布兼容过渡版本，不能直接替换公钥导致旧客户端无法验证。

Fork 默认不运行本仓库的发布任务。独立发行需要自己的应用标识、更新源、签名密钥和发布配置，不能复用本仓库私钥。

当前应用采用 ad-hoc 代码签名，未做 Apple 公证。更新后二进制的代码身份变化，macOS 可能需要重新关联辅助功能和输入监控等原有权限，见[权限引导](permissions.md)。Sparkle 的更新包签名不会绕过系统权限。使用稳定的 Developer ID 签名并完成 Apple 公证是后续正式分发的改进方向。

## 验证

`bash scripts/test.sh` 包括进度、取消、工作中禁止重启以及正确区分最新版本和网络失败的检查。

`python3 scripts/test-updater-integration.py` 在本机回环地址提供临时签名更新，运行独立且不申请麦克风等权限的测试应用。验证实际替换与重启、已经最新、下载取消、篡改列表、篡改安装包和下载地址不可用六种情况。测试使用一次性密钥，不访问真实 freetalk 配置、模型或历史，结果写入忽略提交的 `build/tests/updater-integration/`。
