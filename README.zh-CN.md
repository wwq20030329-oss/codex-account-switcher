# Codex Account Switcher

[English](README.md) | [简体中文](README.zh-CN.md)

Codex Account Switcher 是一个原生 macOS 菜单栏应用，用来保存本地 Codex 登录快照，并在多个账号之间快速切换。

它由两部分组成：

- SwiftUI 菜单栏前端
- 打包进应用内的 Python CLI 后端

这样你就可以管理多个本地 Codex 账号，而不用每次都手动重新登录和重建会话。

## 功能说明

- 将当前本地 Codex 登录状态保存为命名档案
- 一键切换已保存的账号档案
- 显示每个账号的 Codex 套餐和额度信息
- 支持按智能排序或按 `5h` 剩余额度排序
- 支持按档案名、邮箱、套餐搜索
- 高亮推荐下一个最适合切换的账号
- 对当前活跃账号提供低额度提醒
- 支持“连续添加账号”模式，连续导入多个账号
- 支持在应用内开关开机自启
- 支持在应用内检查新版本
- 构建后的 app 会自动包含后端 CLI、应用图标和版本信息

## 安装

先构建应用：

```bash
./build.sh
```

安装到 `~/Applications`：

```bash
./scripts/install.sh
```

安装完成后，打开：

```text
~/Applications/Codex Account Switcher.app
```

构建产物也会输出到：

```text
dist/Codex Account Switcher.app
```

## 首次使用

1. 打开 Codex，并登录一个账号。
2. 打开 Codex Account Switcher。
3. 点击 `Save Current Account` 保存第一个档案。
4. 登录下一个账号后，重复保存流程。
5. 后续通过 `Quick Switch` 或 `Switch Other Accounts` 在多个账号之间切换。

如果你使用“连续添加账号”模式，app 会监听新的本地 Codex 登录状态，并在你完成登录后自动建档。

## 从源码构建

这个项目仅支持 macOS，需要本机安装 Xcode 或 Xcode Command Line Tools 自带的 Swift 工具链。

```bash
./build.sh
```

可选构建参数：

```bash
TARGET_APP="$HOME/Desktop/Codex Account Switcher.app" ./build.sh
```

```bash
VERSION=1.2.3 BUILD_NUMBER=42 ./build.sh
```

## 运行时后端解析顺序

应用启动时，会按下面顺序寻找 CLI 后端：

1. `CODEX_SWITCHER_CLI_PATH`
2. 应用包内自带的 `codex-account-switcher`
3. `~/.local/bin/codex-account-switcher`

## 工作原理

应用会把本地 Codex 登录快照和会话状态保存到：

```text
~/.codex-account-switcher
```

仓库本身不包含任何账号快照或 token。

## 产品打磨项

- `More -> Launch at Login`：把应用注册成 macOS 登录项
- `More -> Check for Updates`：检查 GitHub 最新 release
- `More -> Open Profiles Directory`：直接打开本地档案目录
- 底部会显示当前版本号；如果检测到新版本，也会直接提示

## 已知限制

- 这是一个本地会话切换工具，不是真正的多账号并行登录管理器。
- 某些账号操作仍然可能触发 Codex 重新认证或 MFA。
- 套餐和额度信息依赖当前可用的 Codex 接口以及本地登录状态。
- 检查更新功能在仓库有 GitHub Release 时效果最好。
- 这是一个仅支持 macOS 的项目。

## 项目结构

- `CodexMenuBarApp.swift` - 原生菜单栏应用
- `build.sh` - 构建脚本
- `assets/AppIcon.icns` - 应用图标
- `scripts/codex-account-switcher` - CLI 后端
- `scripts/generate_icon.swift` - 图标生成脚本
- `scripts/install.sh` - 安装到 `~/Applications` 的辅助脚本
- `RELEASE.md` - 发版检查清单

## 说明

- 这个项目与 OpenAI 没有官方关联。
- 构建时会尽量从当前 git 仓库中嵌入版本信息。
- 如果应用找不到内置后端，会回退到 `~/.local/bin/codex-account-switcher`。

## 许可证

MIT
