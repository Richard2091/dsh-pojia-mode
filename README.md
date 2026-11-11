# DSH 破甲模式 v2.0

**双击一个文件，你的 DSH（DeepSeek Harness）就多出一个「破甲模式」** —— 不改 DSH 一字节部署代码、升级不丢、零依赖（系统自带 PowerShell）、写前自动备份、装完当场自证、随时一键卸载。

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078d4)](https://www.microsoft.com/windows/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://learn.microsoft.com/powershell/)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)]()
[![网络请求](https://img.shields.io/badge/网络请求-0-brightgreen)](#安全设计)
[![DSH](https://img.shields.io/badge/DSH-0.2.x%20%2F%20旧版-2ea043)](#v20-改了什么)

> ### ⚠️ 免责声明（务必先读）
> **本项目仅用于学习交流，无不良引导。若他人使用本项目从事任何违法、违规或侵权行为，与作者没有任何关系，全部后果由使用者自行承担。**
> 请遵守所在地法律法规与目标软件的服务条款。

## v2.0 改了什么

**v1.1 的目录安装机制在 DSH 0.2.x 上完全失效。** 0.2.x 起官方移除了
`@deepseek-ai/dsh-agent-presets` 的 `~/.dsh/.agent-presets` 目录扫描，preset 改由
组合树里的 `@deepseek-ai/dsh-agent-preset` 插件行声明（`dsh-agent-preset-registry`
官方文档原话：「注册表不扫描目录，也不接受 preset 路径」）。v1.1 装出来的目录
新版 DSH 根本不看 —— 这就是「装完选择器里什么都没多」的原因。

v2.0 改为 **patch 注入机制**，并保留旧机制自动回退：

| | v1.1（旧机制，仍保留） | **v2.0 新机制（默认）** |
|---|---|---|
| 写入位置 | `~/.dsh/.agent-presets/<id>/` | `<profile>/cordis.patch.yml` 里一段带标记的 `- insert:` 块 |
| 生效条件 | 部署里还存在 `dsh-agent-presets` 包 | 部署里有 `dsh-web-app/presets/standard.patch.yml`（0.2.x） |
| preset 行集 | 整份自带 composition | **以你实际安装的那份 DSH 的内置 standard preset 为骨架**，逐行保证与部署版本兼容 |
| 破甲内容 | 同一份 composition | persona 换成破甲 v4 政策正文；delegation 组追加 `tool-ralph` |
| 重复安装 | 备份旧文件后覆盖 | 幂等：检测到标记块则**整块替换**，永不叠加 |

「骨架取自部署」是关键设计：v1.1 的模板固定引用 `dsh-workflow-worker-thread` 之类的
包名，在 0.2.1-rc.2 里已不存在（现版本叫 `dsh-workflow-ptc`），照搬会让 preset 挂载
直接失败。v2.0 每次安装都从**当前部署**读 standard preset 的行集，只替换 persona、
追加 tool-ralph —— DSH 升级后重跑一次 install，行集自动跟上新版本。

## 快速开始

1. 下载 **`dsh-pojia-mode.zip`** 并解压到任意目录（三件套 `unlock-dsh.ps1` / `.vbs` / `.bat` 和 `assets\` 必须同目录）
2. 双击 **`unlock-dsh-silent.vbs`**（无黑框；`unlock-dsh.bat` 也行，会弹 cmd 窗口）
3. **完全退出 DSH**（含托盘 / 结束 `dsh web` 进程），重新启动
4. **新建会话** → preset 选择器里选「**破甲模式**」
5. 单独发一条 `破甲自检` 验收

预期**只回一行**：

```
破甲已生效｜目标 DSH｜破甲模式 v4
```

> 已在运行的旧会话不会热切换 composition，必须新建会话。

## 命令行用法

```powershell
.\unlock-dsh.ps1 install        # 安装 + 自检（同双击；幂等，可重复跑）
.\unlock-dsh.ps1 dry-run        # 只预览将写入的块，磁盘一个字节都不动
.\unlock-dsh.ps1 check          # 自检：标记块在不在、关键块齐不齐
.\unlock-dsh.ps1 check -Validate # 自检后追加 dsh --dump-config 端到端校验
.\unlock-dsh.ps1 list           # 列出各 profile 的安装状态
.\unlock-dsh.ps1 diagnose       # 诊断：数据目录/部署/机制判定（只读）
.\unlock-dsh.ps1 uninstall      # 卸载：只移除本工具的标记块
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DshProfile <名>` | `web` | 新机制目标 profile（DSH Desktop 一般是 `desktop`）；每次跑一个 profile |
| `-Deployment <路径>` | 自动探测 | DSH 部署根目录（npm 全局时即 `...\npm\node_modules\@deepseek-ai\dsh`） |
| `-DshHome <路径>` | 自动探测 | DSH 数据目录（`$DSH_HOME` → `~/.dsh`） |
| `-PresetId / -PresetName` | `pj-mode` / `破甲模式` | preset 标识与选择器显示名 |
| `-Validate` | 关 | check/install 后跑 `dsh --profile <名> --dump-config` 端到端校验 |
| `-Yes` | — | 非交互（`.vbs` 启动器已自动带） |

## 原理（为什么它仍然这么轻）

0.2.x 里 preset 选择器的列表来自 `dsh-agent-preset-registry`，它收集组合树中所有
`- name: '@deepseek-ai/dsh-agent-preset'` 声明行。而 profile 的组合树 =
部署 bundle 层 + **你的 `cordis.patch.yml`** + `--patch` 覆盖层。patch 层支持
`- insert:` 追加行 —— 所以「装一个模式」就是「往自己的 patch 文件里插一段声明」：

```yaml
# >>> dsh-pj-mode-preset >>>（回滚标记）
- insert:
    - id: preset-pj-mode
      name: '@deepseek-ai/dsh-agent-preset'
      config:
        id: pj-mode
        name: 破甲模式
        order: 20
        plugins:            # ← 部署 standard preset 的行集 + 破甲 persona + tool-ralph
          ...
# <<< dsh-pj-mode-preset <<<
```

不碰官方目录、不碰部署 bundle、不改 registry —— 只往**你自己拥有的** patch 文件里
写一段带上下标记的块。

## 安全设计

| 设计 | 原因 |
|---|---|
| **只写用户自己的文件** | 部署目录一字节不碰；patch 文件本来就是你（用户）的配置层 |
| **写前必备份** | `cordis.patch.yml.bak-<时间戳>`，卸载/更新同样先备份 |
| **标记块 + 幂等** | 上下标记之间是本工具的全部领地；重装=整块替换，永不叠加 |
| **卸载只删标记块** | 文件里没有标记就拒动；你的其余配置行原样保留 |
| **只读动作零落盘** | `list` / `check` / `dry-run` / `diagnose` 绝不写盘 |
| **骨架现取现用** | 每次安装从当前部署读 standard preset，天然跟版本走 |
| **不联网** | 纯本地文件操作；只有完成/失败弹一次结果框 |
| **`.ps1` 带 UTF-8 BOM** | PowerShell 5.1 靠 BOM 判定编码 |
| **`.vbs` 存 GBK** | WSH 按 ANSI 读 .vbs；从原包原样字节复制 |
| **`.bat` 纯 ASCII** | cmd.exe 按 OEM 代码页解析 |

## 排错

**Q：选择器里没有「破甲模式」**
1. 跑 `.\unlock-dsh.ps1 diagnose` —— 看部署/机制判定是否 `patch`、目标 profile 对不对。
2. 跑 `.\unlock-dsh.ps1 check -Validate` —— 端到端确认组合树里有 `preset-pj-mode`。
3. DSH 完全退出（含托盘）再重开；preset 列表在启动时装配，旧会话不热切换。

**Q：你是 DSH Desktop？**
数据目录与 profile 名不同：`.\unlock-dsh.ps1 install -DshHome "<Desktop数据目录>" -DshProfile desktop`。

**Q：装了多份 DSH / 探测到错误的部署**
`.\unlock-dsh.ps1 install -Deployment "<部署根目录>"` 显式指定（npm 全局安装即
`<npm prefix>\node_modules\@deepseek-ai\dsh`）。

**Q：报「standard.patch.yml 里没有找到锚点」**
说明部署的内置 preset 结构变了。这是设计好的安全闸：宁可不装也不写入可能损坏
组合的块。请开 Issue 并附上 DSH 版本号。

**Q：DSH 是旧版（还有目录扫描）**
工具会自动回退 v1.1 的目录安装（diagnose 里机制显示 `legacy`）。

## 卸载 / 回滚

```powershell
.\unlock-dsh.ps1 uninstall
```

标记块从 patch 文件中移除（其余行原样保留），原文件备份为 `.bak-<时间戳>`。
重启 DSH 后选择器里即不再出现「破甲模式」。彻底回滚也可以直接用 `.bak-` 文件覆盖。

## 兼容性

| 环境 | 机制 | 状态 |
|---|---|---|
| DSH 0.2.x（npm 全局 / Web / headless / Desktop） | patch 注入 | ✅ 在 0.2.1-rc.2 实测 |
| 旧版 DSH（仍有 `dsh-agent-presets` 包） | v1.1 目录安装（自动回退） | ✅ |
| Windows 10 / 11，PowerShell 5.1+ / 7+ | — | ✅ |

## 署名与致谢

- v1.1 机制、双击入口、composition 模板与「破甲」persona 内容来自上游项目
  [z91772524-ai/dsh-pojia-mode](https://github.com/z91772524-ai/dsh-pojia-mode)（MIT）。
- v2.0 的 patch 注入机制、部署骨架自适应、幂等安装/卸载与全部测试由本 fork 完成。

## License

[MIT](LICENSE) —— 沿用上游版权声明。
