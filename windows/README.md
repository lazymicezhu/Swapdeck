# Swapdeck Windows 0.1.12 预览版

对应 Mac 源码提交 `91e190c41be44a820036920b0e27adaea28e48ed`。把整个 windows 目录放到 Swapdeck 仓库根目录即可独立构建。本版安装包面向 Windows x64，自带 .NET 10 运行时。

## 使用

安装 Setup.exe 后，从开始菜单打开 Swapdeck。Claude 页面添加中转，Codex 页面支持登录 Lazymice 中转或记录已在 Codex 登录的官方账号。右键卡片可以编辑、重命名或删除。窗口固定为 385 × 650。用量页按线路展示花费，中转优先使用每日消费记录，缺少日记录时按观察到的余额变化统计。官方订阅按可关联账号的本机用量估算。双击「30 天」查看累计记录。实际账单以服务商数据为准。

Claude Code 的用户配置位于 `%USERPROFILE%\.claude\settings.json`。对于 Akko，Swapdeck 仅允许向配置中的官方中转域名发送 GET /v1/usage 查询额度。模型调用由 Claude Code 或获准的桌面客户端直连。请自行填写个人 Key。Claude 桌面第三方模式使用已有的 configLibrary。默认查找 `%APPDATA%\Claude-3p\configLibrary`。桌面端数据目录不同的安装可在设置里选择含 _meta.json 的目录。只启用 CLI 的用户可直接切换，应用会说明实际生效范围。

Codex 使用 CODEX_HOME 或用户目录下的 .codex。遇到自定义 model_provider 时，切换会自动将其改为 openai，并保留原供应商配置段。切换会更新 auth.json 和 config.toml 的顶层 openai_base_url。Codex 对话使用 WSS 直连；仅回环测试允许 WS。握手失败时对话报错。部分需要对同一个地址发起 HTTP 的辅助功能（例如远程压缩）可能无法使用。关闭窗口会保持运行，再次启动可重新打开。完全退出请使用设置中「更多设置」下的「退出切号」。

Swapdeck 的本地数据位于 `%LOCALAPPDATA%\Swapdeck\UserData`。profiles.bin 和配置备份由当前 Windows 用户的 DPAPI 加密。客户端实际使用的配置文件按客户端规定的格式写入。

开启切换后重启时，切号会先尝试正常关闭桌面客户端。主窗口收到关闭请求后 4 秒仍未退出时，切号会再检查一次对话状态，然后强制结束本次识别到的同会话、同安装路径的桌面进程，写入配置并重新打开。强制退出可能丢失客户端中未保存的草稿。

## 开发和测试

使用 Windows、PowerShell 7 和 .NET 10 SDK。以下命令在 windows 目录执行。

```powershell
dotnet build Swapdeck -c Release
dotnet run --project Tests -c Release
dotnet run --project Swapdeck
```

Storage.cs 管理账户文件及切换事务。Clients.cs 处理配置格式。Activity.cs 处理忙碌判断和客户端重启。Network.cs 管理 Akko 网络限制、额度查询及本机转发。History.cs 和 Spend.cs 计算本机用量和余额变化。Updates.cs 验证签名并调用 Velopack。WPF 界面由 MainWindow.xaml、窗口代码、UsageView.cs 和 Dialogs.cs 组成。

## 发布 Windows 更新

使用 Velopack CLI 1.2.161。Windows 的签名文件独立于 Sparkle。release.ps1 从发布目录打包，展开扫描凭据，核对公钥，再对更新清单签名。签名私钥单独保存在本次工作区的 work/windows-release.dpapi，由生成它的 Windows 用户保护。维护者需要保管此文件及该用户的 DPAPI 恢复材料。源码包只带验证公钥。

```powershell
dotnet tool install -g vpk --version 1.2.161
./release.ps1 -Version 0.1.1 -SigningKey <私钥文件路径> -Output <新目录> -Notes <更新说明文件>
```

在 lazymicezhu/Swapdeck 的 GitHub Releases 中使用固定标签 windows-stable。每次先上传带版本号的 full.nupkg，再更新 releases.win-x64.json 和 releases.win-x64.json.sig，附上 Setup.exe。保持资产原名。可将该 Release 标记为预发布，以便继续使用 Mac 的 latest 下载地址。应用启动和运行中每 6 小时检查一次，设置中也可手动检查。用户确认后下载，验证 RSA 签名清单中的 SHA-256，再安装并重启。安装程序的 Authenticode 发布者签名需维护者的 Windows 代码签名证书。

## 当前验证范围

离线验证覆盖 CLI 和第三方配置合并、官方账号与中转切换、回滚日志恢复、忙碌检测、DPAPI、Akko 额度查询和模型请求拦截、WebSocket 配置、更新验签和 WPF 渲染。已在隔离目录完成 0.0.9 至 0.1.0 的实际安装内容替换，并核对用户配置哈希。在线更新需要发布固定标签和资产。

真实 Claude/Codex 桌面端切号后的首轮对话与登录续期仍待测试账号验收。用量页使用本机未压缩的 JSONL 文件，按客户端和模型汇总。和 Mac 版相比，本版尚缺压缩历史与按 ChatGPT 账号归属的精确统计、部分服务商账单导入，以及余量旧数据迁移。
