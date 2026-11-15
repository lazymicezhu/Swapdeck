# Swapdeck（切号）

A small macOS app for switching the accounts and API relays used by the **Claude** and **Codex** desktop apps, with each one's balance and ChatGPT 5-hour / 7-day quota at a glance. Chat history and projects stay intact across switches.

一个 Mac 小应用：切换 Claude 桌面端和 Codex 桌面端使用的账号或中转，并显示各自的余额和 ChatGPT 5 小时 / 7 天额度。切换不影响项目和聊天记录。

## 安装

1. 在 [Releases](https://github.com/lazymicezhu/Swapdeck/releases/latest) 下载最新的 `Swapdeck-x.y.z.dmg`，打开后把「切号」拖进「应用程序」。
2. 第一次打开时系统会提示无法验证：到「系统设置 → 隐私与安全性」，在「安全性」里点「仍要打开」。或者在终端运行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/Swapdeck.app
   ```
3. 之后有新版本会自动提示更新（也可以在菜单「切号 → 检查更新…」里手动检查）。

需要 macOS 15 及以上，Apple 芯片和 Intel 都能用。用法见 [使用说明.md](使用说明.md)。

## 开发

- 构建并安装到本机：`./build.command`（会下载固定版本的 [Sparkle](https://sparkle-project.org) 到 `Vendor/`，并校验哈希）。
- 只打安装包：`./dmg.command`（把已安装的应用做成带安装说明的 dmg）。
- 发布新版本：`./release.command 1.2.0 "更新说明"`。需要本机有 Sparkle 签名私钥。
