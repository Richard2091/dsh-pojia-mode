<#
.SYNOPSIS
    DSH 破甲模式一键安装器 v2.0 —— 给 DeepSeek Harness 装一个「破甲模式」Agent Preset。

.DESCRIPTION
    v2.0 适配 DSH 0.2.x 的新 preset 机制（同时保留 v1.1 旧机制回退）：

    - 0.2.x 起，dsh-agent-preset-registry 只认组合树里的
      `@deepseek-ai/dsh-agent-preset` 插件行，不再扫描 ~/.dsh/.agent-presets
      目录（v1.1 的目录安装在新版完全无效）。
    - 新机制：向目标 profile 的 cordis.patch.yml 追加一段带上下标记的
      `- insert:` 块。块内 plugins 行集以【部署内置 standard preset】
      （dsh-web-app/presets/standard.patch.yml）为骨架，保证与安装的 DSH
      版本逐行兼容；只把 persona 换成破甲 v4 政策正文，并在 delegation 组
      追加 tool-ralph。
    - 旧机制：部署里仍是 dsh-agent-presets 包（或找不到部署）时，按 v1.1
      的方式写 $DSH_HOME\.agent-presets\<id>\ 目录。

    不改 DSH 部署一字节；写前自动备份；卸载只移除本工具自己的标记块；
    检测到标记块已存在时 install 为幂等更新（整块重写，不会叠加）。

    写完必须重启 DSH，并在【新会话】里选「破甲模式」才生效；
    旧会话不会热切换 composition。

.PARAMETER Action
    install    安装 / 幂等更新（默认）
    uninstall  卸载：新机制移除标记块（旧机制把目录移到 _uninstalled-* 备份）
    check      自检：文件就位、关键块齐全
    dry-run    只打印将要写入的内容，磁盘一个字节都不动
    list       列出各 profile 的安装状态（新机制）与已装 preset（旧机制）
    diagnose   诊断：数据目录 / 部署 / 机制判定 / profile 状态（只读）

.PARAMETER PresetId
    preset 标识（目录名 / config.id），默认 pj-mode。

.PARAMETER PresetName
    选择器显示名，默认「破甲模式」。

.PARAMETER DshHome
    显式指定 DSH 数据目录（优先级最高，高于环境变量与自动探测）。

.PARAMETER DshProfile
    新机制目标 profile 名，默认 web。DSH Desktop 常见为 desktop。
    每次运行只作用于一个 profile；多 profile 就多跑几次。

.PARAMETER Deployment
    显式指定 DSH 部署根目录（node_modules\@deepseek-ai\... 的上一层）。
    自动探测失败 / 装了多份 DSH 时使用。

.PARAMETER Validate
    check / install 成功后追加运行 `dsh --profile <DshProfile> --dump-config`
    做端到端校验（需要 dsh 在 PATH 上）。

.PARAMETER Yes
    非交互模式：不弹任何询问。静默启动器（.vbs）会自动带上它。

.EXAMPLE
    .\unlock-dsh.ps1                       # 双击等效：install + 自检
    .\unlock-dsh.ps1 diagnose              # 只读诊断
    .\unlock-dsh.ps1 install -DshProfile desktop
    .\unlock-dsh.ps1 install -Deployment "C:\Users\xx\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh"
    .\unlock-dsh.ps1 check -Validate
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'check', 'dry-run', 'list', 'diagnose')]
    [string]$Action = 'install',

    [string]$PresetId = 'pj-mode',

    [string]$PresetName = '破甲模式',

    [string]$DshHome,

    [string]$DshProfile = 'web',

    [string]$Deployment,

    [switch]$Validate,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ── 常量 ──────────────────────────────────────────────────────────────────────

$Script:UnlockTag  = '破甲已生效｜目标 DSH｜破甲模式 v4'
$Script:MarkerLine = '# [dsh-unlock-mode]'          # 旧机制 composition 标记
$Script:MarkerOpen  = '>>> dsh-pj-mode-preset >>>'  # 新机制 patch 块上标记
$Script:MarkerClose = '<<< dsh-pj-mode-preset <<<'  # 新机制 patch 块下标记
$Script:AssetDir   = Join-Path $PSScriptRoot 'assets'
$Script:CompoFile  = 'agent.cordis.yml'
$Script:MetaFile   = 'preset.yml'

# 只读动作：绝不落盘
$Script:ReadOnlyActions = @('list', 'check', 'dry-run', 'diagnose')

# ── 输出小工具 ────────────────────────────────────────────────────────────────

function Write-Step { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "[X] $m" -ForegroundColor Red }

function Write-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '       DSH 破甲模式 一键安装器                                 ' -ForegroundColor Cyan
    Write-Host '       DeepSeek Harness - Unlock Agent Preset      v2.0       ' -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# ── 环境探测（DSH 数据目录，v1.1 原样保留） ───────────────────────────────────

function Get-DshProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'DSH|deepseek|harness' }
}

$Script:CandList = $null

function Test-LooksLikeDshHome {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($sub in @('.agent-presets', 'profiles', 'sessions', '.credentials.yaml', 'settings.yaml')) {
        if (Test-Path -LiteralPath (Join-Path $Path $sub)) { return $true }
    }
    return $false
}

function Add-DshCandidate {
    param([string]$Path, [string]$Source, [int]$Rank)
    if (-not $Path) { return }
    $p = $Path.Trim().Trim('"')
    if ($p.Length -eq 0) { return }
    $exp = [Environment]::ExpandEnvironmentVariables($p)
    if ($exp.StartsWith('~')) {
        $rest = $exp.Substring(1).TrimStart('\', '/')
        if (-not $env:USERPROFILE) { return }
        $exp = if ($rest.Length -gt 0) { Join-Path $env:USERPROFILE $rest } else { $env:USERPROFILE }
    }
    try { $full = [System.IO.Path]::GetFullPath($exp) } catch { return }
    $exists = Test-Path -LiteralPath $full
    $looks = Test-LooksLikeDshHome -Path $full
    if ($looks) { $Rank += 5 }
    foreach ($c in $Script:CandList) {
        if ($c.Path -ieq $full) {
            if ($Rank -gt $c.Rank) { $c.Rank = $Rank; $c.Source = $Source }
            return
        }
    }
    [void]$Script:CandList.Add([pscustomobject]@{
        Path             = $full
        Source           = $Source
        Rank             = $Rank
        Exists           = $exists
        LooksLikeDshHome = $looks
    })
}

function Get-DshHomeFromLaunchers {
    $result = New-Object System.Collections.ArrayList
    $bases  = @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($b in $bases) {
        $patterns = @(
            (Join-Path $b '*\host-commands\*\bin\dsh.cmd'),
            (Join-Path $b '*\host-commands\*\generations\*\bin\dsh.cmd')
        )
        foreach ($pat in $patterns) {
            Get-ChildItem -Path $pat -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $txt = [System.IO.File]::ReadAllText($_.FullName)
                    $m = [regex]::Match($txt, 'set\s+"DSH_HOME=(?<p>[^"]+)"')
                    if ($m.Success) {
                        [void]$result.Add([pscustomobject]@{
                            Path   = $m.Groups['p'].Value
                            Source = "DSH 启动器记录（$($_.FullName)）"
                        })
                    }
                } catch { }
            }
        }
    }
    return @($result)
}

function Get-DshHomeCandidates {
    param([string]$Explicit)
    $Script:CandList = New-Object System.Collections.ArrayList
    if ($Explicit) {
        Add-DshCandidate -Path $Explicit -Source '命令行 -DshHome 参数' -Rank 110
    }
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim().Length -gt 0) {
        Add-DshCandidate -Path $env:DSH_HOME -Source '环境变量 $env:DSH_HOME' -Rank 100
    }
    foreach ($l in (Get-DshHomeFromLaunchers)) {
        Add-DshCandidate -Path $l.Path -Source $l.Source -Rank 90
    }
    if ($env:USERPROFILE) {
        Add-DshCandidate -Path (Join-Path $env:USERPROFILE '.dsh')      -Source '官方默认位置 ~/.dsh'    -Rank 60
        Add-DshCandidate -Path (Join-Path $env:USERPROFILE '.dsh-beta') -Source 'NEXT Beta 通道默认 ~/.dsh-beta' -Rank 55
        Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.dsh*' -and $_.Name -ne '.dsh' -and $_.Name -ne '.dsh-beta' } |
            Where-Object { Test-LooksLikeDshHome -Path $_.FullName } |
            ForEach-Object { Add-DshCandidate -Path $_.FullName -Source "主目录下的 $($_.Name)" -Rank 40 }
    }
    return @($Script:CandList |
        Sort-Object -Property @{ Expression = 'Rank'; Descending = $true },
                              @{ Expression = 'Exists'; Descending = $true },
                              @{ Expression = 'Path'; Descending = $false })
}

function Resolve-DshHome {
    param([string]$Explicit)
    $cands    = @(Get-DshHomeCandidates -Explicit $Explicit)
    if ($cands.Count -eq 0) {
        throw '无法确定 DSH 数据目录：连 ~/.dsh 都推不出来（$env:USERPROFILE 为空？）。请用 -DshHome 显式指定。'
    }
    $existing = @($cands | Where-Object { $_.Exists })
    if ($Explicit) {
        $hit = $cands | Where-Object { $_.Rank -ge 110 } | Select-Object -First 1
        if ($hit) {
            return [pscustomobject]@{ Candidates = $cands; Chosen = $hit; Ambiguous = $false; ExistingCount = $existing.Count }
        }
    }
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim().Length -gt 0) {
        $hit = $cands | Where-Object { $_.Rank -ge 100 } | Select-Object -First 1
        if ($hit) {
            return [pscustomobject]@{ Candidates = $cands; Chosen = $hit; Ambiguous = $false; ExistingCount = $existing.Count }
        }
    }
    if ($existing.Count -gt 0) { $chosen = $existing[0] } else { $chosen = $cands[0] }
    $ambiguous = ($existing.Count -gt 1) -and ($chosen.Rank -lt 90)
    return [pscustomobject]@{
        Candidates    = $cands
        Chosen        = $chosen
        Ambiguous     = $ambiguous
        ExistingCount = $existing.Count
    }
}

function Show-DshHomeCandidates {
    param($Info)
    Write-Host '  ── DSH_HOME 候选 ─────────────────────────────────────' -ForegroundColor DarkCyan
    foreach ($c in $Info.Candidates) {
        $mark  = if ($c.Path -ieq $Info.Chosen.Path) { '  [选中]' } else { '        ' }
        $ex    = if ($c.Exists) { '存在' } else { '不存在' }
        $color = if ($c.Path -ieq $Info.Chosen.Path) { 'Cyan' } else { 'DarkGray' }
        Write-Host ("  {0} {1,-58} {2}  (分 {3})" -f $mark, $c.Path, $ex, $c.Rank) -ForegroundColor $color
        Write-Host ("            来源：{0}" -f $c.Source) -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ── 环境探测（DSH 部署目录，v2.0 新增） ────────────────────────────────────────

function Test-DeploymentKind {
    <# 'modern' = 0.2.x（preset 走插件行）；'legacy' = 旧版目录扫描包还在；'unknown' #>
    param([string]$Root)
    if (-not $Root) { return 'unknown' }
    if (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@deepseek-ai\dsh-web-app\presets\standard.patch.yml')) { return 'modern' }
    if (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@deepseek-ai\dsh-agent-presets')) { return 'legacy' }
    return 'unknown'
}

function Resolve-DeploymentRoot {
    <# npm prefix（含 dsh.cmd 的目录）→ 解析到真正的部署包根 node_modules\@deepseek-ai\dsh #>
    param([string]$Path)
    if (-not $Path) { return $Path }
    $inner = Join-Path $Path 'node_modules\@deepseek-ai\dsh'
    if (Test-Path -LiteralPath (Join-Path $inner 'package.json')) { return $inner }
    return $Path
}

function Get-DshDeploymentCandidates {
    param([string]$Explicit)

    $list = New-Object System.Collections.ArrayList
    function Add-Deployment([string]$Path, [string]$Source) {
        if (-not $Path) { return }
        $p = $Path.Trim().Trim('"')
        if ($p.Length -eq 0) { return }
        try { $p = [System.IO.Path]::GetFullPath($p) } catch { return }
        if (-not (Test-Path -LiteralPath $p)) { return }
        $p = Resolve-DeploymentRoot -Path $p
        foreach ($c in @($list)) { if ($c.Root -ieq $p) { return } }
        [void]$list.Add([pscustomobject]@{ Root = $p; Source = $Source; Kind = (Test-DeploymentKind -Root $p) })
    }

    if ($Explicit) { Add-Deployment $Explicit '命令行 -Deployment 参数' }

    $cmd = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.CommandType -eq 'Application' -and $cmd.Source) {
        Add-Deployment (Split-Path $cmd.Source -Parent) "PATH 上的 dsh 命令（$($cmd.Source)）"
    }

    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if ($base) { Add-Deployment (Join-Path $base 'npm') 'npm 全局目录' }
    }

    return @($list)
}

function Resolve-DshDeployment {
    param([string]$Explicit)
    $cands = @(Get-DshDeploymentCandidates -Explicit $Explicit)
    $modern = @($cands | Where-Object { $_.Kind -eq 'modern' })
    if ($modern.Count -gt 0) { return $modern[0] }
    if ($cands.Count -gt 0) { return $cands[0] }
    return $null
}

function Show-DeploymentCandidates {
    param($Candidates, $Chosen, [string]$Mechanism)
    Write-Host '  ── DSH 部署候选 ─────────────────────────────────────' -ForegroundColor DarkCyan
    if (@($Candidates).Count -eq 0) {
        Write-Host '  （未找到任何部署 —— 新机制不可用，将回退旧机制目录安装）' -ForegroundColor Yellow
        Write-Host ''
        return
    }
    foreach ($c in $Candidates) {
        $mark  = if ($Chosen -and $c.Root -ieq $Chosen.Root) { '  [选中]' } else { '        ' }
        $kind  = switch ($c.Kind) { 'modern' { '0.2.x 新机制' } 'legacy' { '旧版目录扫描' } default { '未知布局' } }
        $color = if ($Chosen -and $c.Root -ieq $Chosen.Root) { 'Cyan' } else { 'DarkGray' }
        Write-Host ("  {0} {1}" -f $mark, $c.Root) -ForegroundColor $color
        Write-Host ("            来源：{0}   布局：{1}" -f $c.Source, $kind) -ForegroundColor DarkGray
    }
    Write-Host ("  机制判定：{0}" -f $(if ($Mechanism -eq 'patch') { 'patch（写 profile 的 cordis.patch.yml）' } else { 'legacy（写 ~/.dsh/.agent-presets，仅旧版 DSH 有效）' }))
    Write-Host ''
}

# ── 资源载入 ──────────────────────────────────────────────────────────────────

function Read-Asset {
    param([string]$Name)
    $p = Join-Path $Script:AssetDir $Name
    if (-not (Test-Path $p)) {
        throw "缺少资源文件：$p`n请确认已完整解压本工具（assets 目录必须与脚本在一起）。"
    }
    return [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}

# ── 新机制（v2.0）：向 profile 的 cordis.patch.yml 注入带标记的 - insert: 块 ──

function Get-PatchFilePath {
    param([string]$DshHome, [string]$ProfileName)
    if ($ProfileName -notmatch '^[A-Za-z0-9_\-]+$') {
        throw "profile 名含非法字符：$ProfileName"
    }
    return Join-Path (Join-Path $DshHome ('profiles\' + $ProfileName)) 'cordis.patch.yml'
}

function Split-PatchText {
    <# 返回 Present / Before / Block / After。Before 以换行结尾或为空。 #>
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    $openTag  = '# ' + $Script:MarkerOpen
    $closeTag = '# ' + $Script:MarkerClose
    $o = -1; $c = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($o -lt 0) {
            if ($lines[$i].StartsWith($openTag)) { $o = $i }
        } elseif ($lines[$i].StartsWith($closeTag)) { $c = $i; break }
    }
    if ($o -ge 0 -and $c -gt $o) {
        $before = ''
        if ($o -gt 0) { $before = (($lines[0..($o - 1)] -join "`r`n") + "`r`n") }
        $block = ($lines[$o..$c] -join "`r`n")
        $after = ''
        if ($c + 1 -le $lines.Count - 1) { $after = ($lines[($c + 1)..($lines.Count - 1)] -join "`r`n") }
        return @{ Present = $true; Before = $before; Block = $block; After = $after }
    }
    return @{ Present = $false; Before = $Text; Block = ''; After = '' }
}

function Build-PatchBlock {
    param([string]$DeploymentRoot, [string]$Stamp)

    $stdPath = Join-Path $DeploymentRoot 'node_modules\@deepseek-ai\dsh-web-app\presets\standard.patch.yml'
    if (-not (Test-Path -LiteralPath $stdPath)) {
        throw "部署里找不到内置 standard preset：$stdPath"
    }
    $stdLines = [System.IO.File]::ReadAllLines($stdPath)

    $iSA = -1
    for ($i = 0; $i -lt $stdLines.Count; $i++) {
        if ($stdLines[$i] -match '^\s*- id: agent-instructions$') { $iSA = $i; break }
    }
    if ($iSA -lt 0) {
        throw "standard.patch.yml 里没有找到 '- id: agent-instructions' 锚点 —— 该 DSH 版本的结构已变化，本工具无法安全注入。请带上这份文件的路径到项目 Issues 反馈。"
    }
    $stdBody = @($stdLines[$iSA..($stdLines.Count - 1)])

    # 模板 persona 块（^- id: persona$ 起、^- id: agent-instructions$ 止），整体右移 10 格
    $tmplLines = (Read-Asset 'agent.cordis.yml.tmpl') -split "`r?`n"
    $iP = -1; $iA = -1
    for ($i = 0; $i -lt $tmplLines.Count; $i++) {
        if ($iP -lt 0 -and $tmplLines[$i] -match '^\s*- id: persona$') { $iP = $i }
        if ($tmplLines[$i] -match '^\s*- id: agent-instructions$') { $iA = $i; break }
    }
    if ($iP -lt 0 -or $iA -le $iP) { throw "assets 模板里找不到 persona 块（agent.cordis.yml.tmpl 结构变了？）。" }
    $persona = foreach ($l in $tmplLines[$iP..($iA - 1)]) {
        if ($l.Trim() -eq '') { '' } else { ('          ' + $l) }
    }

    $agentInstr = @(
        '          - id: agent-instructions',
        "            name: '@deepseek-ai/dsh-agent-instructions'",
        '            config:',
        '              maxBytes: 65536'
    )

    # delegation 组里 tool-workflow 行后追加 tool-ralph（找不到锚点就静默跳过，不影响安装）
    $iWf = -1
    for ($i = 0; $i -lt $stdBody.Count; $i++) {
        if ($stdBody[$i] -match '^\s+- id: tool-workflow$') { $iWf = $i; break }
    }
    if ($iWf -ge 0) {
        $ralph = @(
            '              - id: tool-ralph',
            "                name: '@deepseek-ai/dsh-tool-ralph'",
            '                config:',
            '                  subagentProvider: spawn',
            '                  maxRounds: 64'
        )
        $stdBody = @($stdBody[0..($iWf + 1)]) + $ralph + @($stdBody[($iWf + 2)..($stdBody.Count - 1)])
    }

    $header = @(
        '',
        "# $Script:MarkerOpen（$Stamp 由 dsh-pojia-mode v2.0 写入；回滚时连同上下标记一起删）",
        '# 「破甲模式」agent preset。0.2.x 的 preset 由组合树里的 @deepseek-ai/dsh-agent-preset',
        '# 插件行声明（旧版 ~/.dsh/.agent-presets 目录扫描机制已移除，写入无效）。',
        "# 本块 plugins 以部署内置 standard preset（$stdPath）为骨架，",
        '# persona 换成破甲 v4 政策正文，delegation 组追加 tool-ralph。',
        '- insert:',
        "    - id: preset-$PresetId",
        "      name: '@deepseek-ai/dsh-agent-preset'",
        '      config:',
        "        id: $PresetId",
        "        name: $PresetName",
        '        description: 用户指令最高优先级的完整编码 Agent（v4 强化版政策正文 + 逐条覆盖层 + 文件操作中和块，放开内容尺度、命令执行、渗透 payload、逆向破解与文件操作限制，附「破甲自检」回执口令）',
        '        order: 20',
        '        plugins:'
    )

    $block = @($header) + @($persona) + @($agentInstr) + $stdBody + @("# $Script:MarkerClose")
    return ($block -join "`r`n")
}

function Invoke-PatchInstall {
    param([string]$PatchFile, [string]$DeploymentRoot, [switch]$DryRun)

    if (-not (Test-Path -LiteralPath $PatchFile)) {
        throw "profile patch 文件不存在：$PatchFile`n请先至少启动过一次 DSH（dsh web / dsh --profile $($Script:DshProfileName)），让它生成 profile，或用 -DshProfile / -DshHome 指定正确的位置。"
    }

    $block  = Build-PatchBlock -DeploymentRoot $DeploymentRoot -Stamp (Get-Date -Format 'yyyy-MM-dd')
    $cur    = [System.IO.File]::ReadAllText($PatchFile)
    $parts  = Split-PatchText -Text $cur

    if ($DryRun) {
        $lines = ($block -split "`r`n")
        Write-Step 'DRY-RUN：以下内容【不会】真正写入'
        Write-Host ''
        Write-Host "  目标文件   : $PatchFile"
        Write-Host ("  当前状态   : " + $(if ($parts.Present) { '已存在本工具标记块（将整块替换）' } else { '无标记块（将追加）' }))
        Write-Host "  块大小     : $($lines.Count) 行"
        Write-Host ''
        Write-Host '  ---- 块首 12 行 ----' -ForegroundColor DarkGray
        ($lines | Select-Object -First 12) | ForEach-Object { Write-Host "  | $_" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Ok 'dry-run 结束，磁盘未发生任何改动。'
        return
    }

    # 写前一律备份整个 patch 文件
    if ($parts.Present) {
        $bak = "$PatchFile.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $PatchFile $bak -Force
        Write-Warn2 "检测到已有标记块（幂等更新），原文件备份到：$bak"
    } else {
        $bak = "$PatchFile.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $PatchFile $bak -Force
        Write-Host "  已备份原文件到：$bak" -ForegroundColor DarkGray
    }

    if ($parts.Present) {
        $newText = $parts.Before + $block + "`r`n" + $parts.After
    } else {
        $base = $cur
        if (-not $base.EndsWith("`n")) { $base += "`r`n" }
        $newText = $base + $block + "`r`n"
    }

    $enc = New-Object System.Text.UTF8Encoding($false)   # 无 BOM，DSH 的 YAML 加载器要求
    [System.IO.File]::WriteAllText($PatchFile, $newText, $enc)

    if ($parts.Present) {
        Write-Ok "已整块替换标记块：$PatchFile"
    } else {
        Write-Ok "已追加标记块：$PatchFile"
    }
    Write-Ok "块内 preset：config.id=$PresetId，显示名=$PresetName，行集骨架取自部署 standard preset"
}

function Invoke-PatchUninstall {
    param([string]$PatchFile)

    if (-not (Test-Path -LiteralPath $PatchFile)) {
        Write-Warn2 "未找到 $PatchFile ，无需卸载。"
        return $true
    }
    $cur   = [System.IO.File]::ReadAllText($PatchFile)
    $parts = Split-PatchText -Text $cur
    if (-not $parts.Present) {
        Write-Warn2 '该 patch 文件里没有本工具的标记块，未做任何改动。'
        return $true
    }

    $bak = "$PatchFile.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $PatchFile $bak -Force

    $newText = $parts.Before + $parts.After
    # 收敛多余空行：Before 结尾换行 + After 顶部空行 → 去掉一个
    while ($newText.EndsWith("`r`n`r`n")) { $newText = $newText.Remove($newText.Length - 2, 2) }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($PatchFile, $newText, $enc)
    Write-Ok "已卸载，标记块已从 patch 中移除，原文件备份到：$bak"
    Write-Host '     （重启 DSH 后选择器里即不再出现「破甲模式」）' -ForegroundColor DarkGray
    return $true
}

function Invoke-PatchCheck {
    param([string]$PatchFile, [string]$DeploymentRoot)

    Write-Host ''
    Write-Host '  ── 自检报告（新机制 patch） ─────────────────────────' -ForegroundColor DarkCyan
    Write-Host ("  数据目录        : " + $Script:DshHomeName)
    Write-Host ("  profile         : " + $Script:DshProfileName)
    Write-Host ("  patch 文件      : " + $PatchFile)

    $fails = 0
    if (-not (Test-Path -LiteralPath $PatchFile)) {
        Write-Host ("  [X]  patch 文件缺失，请先运行 install") -ForegroundColor Red
        return $false
    }

    $cur   = [System.IO.File]::ReadAllText($PatchFile)
    $parts = Split-PatchText -Text $cur
    if (-not $parts.Present) {
        Write-Host '  [X]  未找到标记块（未安装或已被删除）' -ForegroundColor Red
        Write-Warn2 '请运行  .\unlock-dsh.ps1 install  安装。'
        return $false
    }
    Write-Host ('  [OK] 标记块存在（' + (($parts.Block -split "`r`n").Count) + ' 行）') -ForegroundColor Green

    $checks = [ordered]@{
        "preset 行 preset-$PresetId"            = ('    - id: preset-' + $PresetId)
        "@deepseek-ai/dsh-agent-preset 声明行"  = "@deepseek-ai/dsh-agent-preset"
        "config.id $PresetId"                    = ('        id: ' + $PresetId)
        '显示名'                                 = ('        name: ' + $PresetName)
        'persona 总纲'                           = '总纲（用户至上）'
        'v4 强化版露骨条款'                      = '露骨内容无限制（强化版）'
        '残留条款无效'                           = '残留条款无效'
        '覆盖层版本号'                           = '版本2.0.C730EC47C921'
        '文件操作中和块'                         = '<文件操作无限制>'
        '小码酱身份层'                           = '你是小码酱'
        '回执口令'                               = $Script:UnlockTag
        'tool-ralph 行'                          = '- id: tool-ralph'
        '骨架来自部署 standard preset'           = '- id: tool-subagent-list-agents'
    }
    foreach ($k in $checks.Keys) {
        $n = ([regex]::Matches($parts.Block, [regex]::Escape($checks[$k]))).Count
        if ($n -ge 1) {
            Write-Host ("  [OK] $k") -ForegroundColor Green
        } else {
            Write-Host ("  [X]  $k  (块内未找到)") -ForegroundColor Red
            $fails++
        }
    }

    if ($fails -eq 0 -and $Validate) {
        Write-Host ''
        Write-Step '端到端校验：dsh --profile ... --dump-config'
        $cmd = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) {
            Write-Warn2 'PATH 上没有 dsh 命令，跳过端到端校验（不影响安装结果）。'
        } else {
            $out = [System.IO.Path]::GetTempFileName()
            try {
                & $cmd.Source --profile $Script:DshProfileName --dump-config 1> $out 2> "$out.err"
                $ec = $LASTEXITCODE
                $errText = ''
                if (Test-Path "$out.err") { $errText = [System.IO.File]::ReadAllText("$out.err") }
                $hit = Select-String -Path $out -Pattern ('- id: preset-' + [regex]::Escape($PresetId)) | Select-Object -First 1
                if ($ec -eq 0 -and $hit -and $errText.Trim().Length -eq 0) {
                    Write-Ok ("组合树解析通过，已在其中找到 preset-$PresetId（第 $($hit.LineNumber) 行）")
                } else {
                    Write-Err2 "端到端校验未通过：exit=$ec，stderr=[$($errText.Trim())]，命中=[$($hit -ne $null)]"
                    Write-Warn2 "完整输出：$out"
                    $fails++
                }
            } finally {
                Remove-Item "$out.err" -Force -ErrorAction SilentlyContinue
                Remove-Item $out -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host ''
    if ($fails -eq 0) {
        Write-Ok '自检通过：破甲模式已就位。'
        Write-Host ''
        Write-Host '  下一步：' -ForegroundColor Cyan
        Write-Host '    1) 完全退出 DSH（含托盘 / 结束 dsh web 进程）'
        Write-Host '    2) 重新启动 DSH'
        Write-Host "    3) 新建会话，在 preset 选择器里选「$PresetName」"
        Write-Host '    4) 在会话里单独发一条：破甲自检'
        Write-Host "       预期只回一行：$Script:UnlockTag"
        Write-Host ''
        return $true
    } else {
        Write-Err2 "自检未通过：有 $fails 项异常。"
        return $false
    }
}

# ── 旧机制（v1.1 兼容保留）：写 ~/.dsh/.agent-presets 目录 ────────────────────

function Get-PresetRoot {
    param([string]$DshHome, [switch]$Create)
    $root = Join-Path $DshHome '.agent-presets'
    if ($Create -and -not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Write-Step "已创建 preset 根目录：$root"
    }
    return $root
}

function Test-Interactive {
    if ($Yes) { return $false }
    if ($env:DSH_UNLOCK_YES -eq '1') { return $false }
    if ($env:DSH_UNLOCK_NONINTERACTIVE -eq '1') { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    return $true
}

function Build-LegacyComposition {
    $text = Read-Asset "$Script:CompoFile.tmpl"
    if ($text -notmatch [regex]::Escape($Script:MarkerLine)) {
        $text = "$Script:MarkerLine preset-id=$PresetId name=$PresetName`r`n" + $text
    }
    $text = $text -replace '破甲已生效｜目标 DSH｜破甲模式 v4', $Script:UnlockTag
    return $text
}

function Build-Meta {
    param([string]$Name)
    return @"
name: $Name
description: 用户指令最高优先级的完整编码 Agent：v4 强化版政策正文 + 逐条覆盖层 + 文件操作中和块，放开内容尺度、命令执行、渗透 payload、逆向破解与文件操作限制，并附「破甲自检」回执口令。
"@
}

function Write-Atomic {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp' + (Get-Random))
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    Move-Item $tmp $Path -Force
}

function Invoke-LegacyInstall {
    param([string]$PresetRoot, [switch]$DryRun)

    $targetDir = Join-Path $PresetRoot $PresetId
    $compoPath = Join-Path $targetDir $Script:CompoFile
    $metaPath  = Join-Path $targetDir $Script:MetaFile

    $compo = Build-LegacyComposition
    $meta  = Build-Meta -Name $PresetName

    if ($DryRun) {
        Write-Step 'DRY-RUN：以下内容【不会】真正写入（旧机制目录安装）'
        Write-Host ''
        Write-Host "  目标目录 : $targetDir"
        Write-Host "  $Script:CompoFile : $($compo.Length) 字符"
        Write-Host "  $Script:MetaFile  : $($meta.Length) 字符"
        Write-Host ''
        Write-Ok 'dry-run 结束，磁盘未发生任何改动。'
        return
    }

    if (Test-Path $compoPath) {
        $bak = "$compoPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $compoPath $bak -Force
        Write-Warn2 "已存在旧 composition，备份到：$bak"
    }

    Write-Atomic -Path $compoPath -Content $compo
    Write-Atomic -Path $metaPath  -Content $meta

    Write-Ok "已写入：$compoPath  ($($compo.Length) 字符)"
    Write-Ok "已写入：$metaPath  ($($meta.Length) 字符)"
}

function Invoke-LegacyUninstall {
    param([string]$PresetRoot)
    $targetDir = Join-Path $PresetRoot $PresetId
    if (-not (Test-Path $targetDir)) {
        Write-Warn2 "未找到 $targetDir ，无需卸载。"
        return $true
    }
    $compoPath = Join-Path $targetDir $Script:CompoFile
    if (Test-Path $compoPath) {
        $head = [System.IO.File]::ReadAllText($compoPath, (New-Object System.Text.UTF8Encoding($false)))
        if ($head -notmatch [regex]::Escape($Script:MarkerLine)) {
            Write-Err2 "该目录不是本工具安装的（缺少 $Script:MarkerLine 标记），为安全起见不予删除。"
            Write-Warn2 "如确认要删，请手动删除：$targetDir"
            return $false
        }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $trash = Join-Path $PresetRoot ("_uninstalled-$PresetId-$stamp")
    Move-Item $targetDir $trash -Force
    Write-Ok "已卸载，原目录移动到：$trash"
    Write-Host "     （确认无误后可手动删除该备份目录）" -ForegroundColor DarkGray
    return $true
}

function Invoke-LegacyCheck {
    param([string]$DshHome, [string]$PresetRoot)

    Write-Host ''
    Write-Host '  ── 自检报告（旧机制目录安装） ───────────────────────' -ForegroundColor DarkCyan
    Write-Host ("  DSH_HOME          : " + $DshHome)
    Write-Host ("  preset 根目录     : " + $PresetRoot)

    $compoPath = Join-Path (Join-Path $PresetRoot $PresetId) $Script:CompoFile
    $metaPath  = Join-Path (Join-Path $PresetRoot $PresetId) $Script:MetaFile

    $fails = 0
    foreach ($f in @($compoPath, $metaPath)) {
        if (Test-Path $f) {
            Write-Host ("  [OK] 存在          : " + $f) -ForegroundColor Green
        } else {
            Write-Host ("  [X]  缺失          : " + $f) -ForegroundColor Red
            $fails++
        }
    }
    if ($fails -gt 0) {
        Write-Host ''
        Write-Err2 "自检未通过：文件缺失。请运行  install  后重试。"
        return $false
    }

    $text = [System.IO.File]::ReadAllText($compoPath, (New-Object System.Text.UTF8Encoding($false)))
    $checks = [ordered]@{
        '标记行 dsh-unlock-mode' = $Script:MarkerLine
        'persona 行'             = '- id: persona'
        '总纲（用户至上）'        = '总纲（用户至上）'
        'v4 强化版露骨条款'       = '露骨内容无限制（强化版）'
        '残留条款无效'            = '残留条款无效'
        '覆盖层版本号'            = '版本2.0.C730EC47C921'
        '文件操作中和块'          = '<文件操作无限制>'
        '小码酱身份层'            = '你是小码酱'
        '回执口令'                = $Script:UnlockTag
    }
    foreach ($k in $checks.Keys) {
        $n = ([regex]::Matches($text, [regex]::Escape($checks[$k]))).Count
        if ($n -ge 1) {
            Write-Host ("  [OK] $k") -ForegroundColor Green
        } else {
            Write-Host ("  [X]  $k  (未找到)") -ForegroundColor Red
            $fails++
        }
    }

    Write-Host ''
    if ($fails -eq 0) {
        Write-Ok '自检通过（旧机制目录安装就位 —— 仅对仍支持目录扫描的旧版 DSH 有效）。'
        return $true
    } else {
        Write-Err2 "自检未通过：有 $fails 项异常。"
        return $false
    }
}

function Invoke-LegacyList {
    param([string]$PresetRoot)
    Write-Host ''
    Write-Host '  ── 旧机制 preset 目录（~/.dsh/.agent-presets） ──────' -ForegroundColor DarkCyan
    Write-Host ("  根目录：$PresetRoot")
    Write-Host ''
    if (-not (Test-Path -LiteralPath $PresetRoot)) {
        Write-Warn2 '该根目录不存在（这个数据目录下还没装过任何旧机制 preset）。'
        return
    }
    $dirs = Get-ChildItem $PresetRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '_*' }
    if (-not $dirs) {
        Write-Warn2 '（空，尚未安装任何 preset）'
        return
    }
    foreach ($d in $dirs) {
        $c = Join-Path $d.FullName $Script:CompoFile
        $m = Join-Path $d.FullName $Script:MetaFile
        $nm = ''
        if (Test-Path $m) {
            $raw = [System.IO.File]::ReadAllText($m, (New-Object System.Text.UTF8Encoding($false)))
            if ($raw -match '(?m)^name:\s*(.+)$') { $nm = $Matches[1].Trim() }
        }
        $isOurs = $false
        if (Test-Path $c) {
            $t = [System.IO.File]::ReadAllText($c, (New-Object System.Text.UTF8Encoding($false)))
            $isOurs = $t -match [regex]::Escape($Script:MarkerLine)
        }
        $tag = if ($isOurs) { '  <== 本工具安装（旧机制）' } else { '' }
        $size = if (Test-Path $c) { (Get-Item $c).Length } else { 0 }
        Write-Host ("  {0,-14} {1,-12} {2,8} B{3}" -f $d.Name, $nm, $size, $tag)
    }
    Write-Host ''
}

# ── 新机制 list / 诊断 ────────────────────────────────────────────────────────

function Invoke-PatchList {
    param([string]$DshHome)
    Write-Host ''
    Write-Host '  ── 新机制：各 profile 安装状态 ──────────────────────' -ForegroundColor DarkCyan
    $profilesRoot = Join-Path $DshHome 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        Write-Warn2 "未找到 $profilesRoot （还没启动过 DSH？）"
        return
    }
    $dirs = Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) { Write-Warn2 '（没有任何 profile）'; return }
    foreach ($d in $dirs) {
        $pf = Join-Path $d.FullName 'cordis.patch.yml'
        if (-not (Test-Path -LiteralPath $pf)) {
            Write-Host ("  {0,-12} （无 cordis.patch.yml，跳过）" -f $d.Name) -ForegroundColor DarkGray
            continue
        }
        $parts = Split-PatchText -Text ([System.IO.File]::ReadAllText($pf))
        $state = if ($parts.Present) { '已安装破甲模式' } else { '未安装' }
        $color = if ($parts.Present) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0,-12} {1}   （{2}）" -f $d.Name, $state, $pf) -ForegroundColor $color
    }
    Write-Host ''
}

function Show-UnifiedDiagnose {
    param($HomeInfo, $Deployment, [string]$Mechanism, [string]$DshHome)

    Show-DshHomeCandidates -Info $HomeInfo
    Show-DeploymentCandidates -Candidates (Get-DshDeploymentCandidates) -Chosen $Deployment -Mechanism $Mechanism

    Write-Host '  ── 判定结论 ─────────────────────────────────────────' -ForegroundColor DarkCyan
    Write-Host ("  选定数据目录 : " + $HomeInfo.Chosen.Path) -ForegroundColor Cyan
    Write-Host ("  判定来源     : " + $HomeInfo.Chosen.Source)
    if ($Mechanism -eq 'patch' -and $Deployment) {
        Write-Host ("  部署根目录   : " + $Deployment.Root) -ForegroundColor Cyan
        Write-Host ("  部署来源     : " + $Deployment.Source)
    }

    Write-Host ''
    Write-Host '  ── 新机制 patch 状态 ────────────────────────────────' -ForegroundColor DarkCyan
    $profilesRoot = Join-Path $DshHome 'profiles'
    if (Test-Path -LiteralPath $profilesRoot) {
        foreach ($d in (Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
            $pf = Join-Path $d.FullName 'cordis.patch.yml'
            if (Test-Path -LiteralPath $pf) {
                $parts = Split-PatchText -Text ([System.IO.File]::ReadAllText($pf))
                $state = if ($parts.Present) { '含本工具标记块' } else { '无标记块' }
                Write-Host ("  profiles\{0}\cordis.patch.yml  →  {1}" -f $d.Name, $state)
            } else {
                Write-Host ("  profiles\{0}\cordis.patch.yml  →  文件不存在" -f $d.Name)
            }
        }
    } else {
        Write-Host ("  " + $profilesRoot + "  →  不存在")
    }
    $pf = Get-PatchFilePath -DshHome $DshHome -ProfileName $Script:DshProfileName
    Write-Host ("  本次目标（-DshProfile $($Script:DshProfileName)）：$pf  →  " + $(if (Test-Path -LiteralPath $pf) { '存在' } else { '不存在' }))

    Write-Host ''
    Write-Host '  ── 旧机制 preset 根目录 ─────────────────────────────' -ForegroundColor DarkCyan
    $legacyRoot = Join-Path $DshHome '.agent-presets'
    Write-Host ("  " + $legacyRoot + "  →  " + $(if (Test-Path -LiteralPath $legacyRoot) { '存在（注意：0.2.x 不再扫描此目录）' } else { '不存在' }))

    Write-Host ''
    Write-Host '  ── 运行中的 DSH 进程 ────────────────────────────────' -ForegroundColor DarkCyan
    $procs = @(Get-DshProcesses)
    if ($procs.Count -eq 0) {
        Write-Host '  （未检测到 DSH 进程）'
    } else {
        foreach ($p in ($procs | Select-Object -First 8)) {
            $path = ''
            try { $path = $p.Path } catch { }
            Write-Host ("  " + $p.ProcessName + "  pid=" + $p.Id + "  " + $path) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '  ── 手工覆盖 ─────────────────────────────────────────' -ForegroundColor DarkCyan
    Write-Host '  数据目录不对：  .\unlock-dsh.ps1 install -DshHome "你的\DSH数据目录"'
    Write-Host '  profile 不对：  .\unlock-dsh.ps1 install -DshProfile <名字>'
    Write-Host '  部署探测不对：  .\unlock-dsh.ps1 install -Deployment "部署根目录"'
    Write-Host ''
}

function Assert-NoWrite {
    param([string]$Root, [bool]$ExistedBefore)
    if ($ExistedBefore) { return }
    if (Test-Path -LiteralPath $Root) {
        Write-Err2 "内部缺陷：只读动作竟然创建了 $Root —— 请把这段输出反馈给作者。"
        exit 2
    }
}

# ── 主流程 ────────────────────────────────────────────────────────────────────

Write-Banner

$readOnly = ($Script:ReadOnlyActions -contains $Action)

try {
    # 0) 上下文给 patch/legacy 共用的检查函数用
    $Script:DshProfileName = $DshProfile

    # 1) 数据目录
    $homeInfo = Resolve-DshHome -Explicit $DshHome
    $chosen   = $homeInfo.Chosen
    $dshHome  = $chosen.Path
    $Script:DshHomeName = $dshHome

    # 2) 部署与机制
    $deployInfo = Resolve-DshDeployment -Explicit $Deployment
    $mechanism  = 'legacy'
    if ($deployInfo -and $deployInfo.Kind -eq 'modern') { $mechanism = 'patch' }

    Write-Host "  DSH 数据目录  : $dshHome"
    Write-Host "  判定来源      : $($chosen.Source)"
    if (-not $chosen.Exists) {
        Write-Warn2 '该数据目录当前不存在 —— 首次安装 DSH / 还没启动过时属正常，install 会按需创建。'
    }
    if ($deployInfo) {
        Write-Host "  DSH 部署      : $($deployInfo.Root)（$($deployInfo.Kind)）"
    } else {
        Write-Warn2 '未找到 DSH 部署目录 —— 无法使用 0.2.x 新机制，将按旧机制写入目录（仅旧版 DSH 有效）。可用 -Deployment 显式指定。'
    }
    Write-Host ("  安装机制      : " + $(if ($mechanism -eq 'patch') { 'patch（profile 的 cordis.patch.yml 注入，0.2.x）' } else { 'legacy（.agent-presets 目录，仅旧版 DSH）' }))
    if ($mechanism -eq 'patch') { Write-Host "  目标 profile  : $DshProfile" }
    Write-Host "  preset id     : $PresetId"
    Write-Host "  显示名        : $PresetName"
    Write-Host ''

    # ── 新机制分支 ──
    if ($mechanism -eq 'patch') {
        $patchFile = Get-PatchFilePath -DshHome $dshHome -ProfileName $DshProfile

        if ($Action -eq 'diagnose') {
            Show-UnifiedDiagnose -HomeInfo $homeInfo -Deployment $deployInfo -Mechanism $mechanism -DshHome $dshHome
            exit 0
        }
        if ($Action -eq 'list')     { Invoke-PatchList -DshHome $dshHome; exit 0 }
        if ($Action -eq 'dry-run')  { Invoke-PatchInstall -PatchFile $patchFile -DeploymentRoot $deployInfo.Root -DryRun; exit 0 }
        if ($Action -eq 'install')  {
            Invoke-PatchInstall -PatchFile $patchFile -DeploymentRoot $deployInfo.Root
            Invoke-PatchCheck -PatchFile $patchFile -DeploymentRoot $deployInfo.Root | Out-Null
            exit 0
        }
        if ($Action -eq 'uninstall'){ [void](Invoke-PatchUninstall -PatchFile $patchFile); exit 0 }
        if ($Action -eq 'check')    { [void](Invoke-PatchCheck -PatchFile $patchFile -DeploymentRoot $deployInfo.Root); exit 0 }
    }

    # ── 旧机制分支（v1.1 行为） ──
    $presetRoot = Join-Path $dshHome '.agent-presets'
    $rootExistedBefore = Test-Path -LiteralPath $presetRoot

    if ($Action -eq 'diagnose') {
        Show-UnifiedDiagnose -HomeInfo $homeInfo -Deployment $deployInfo -Mechanism $mechanism -DshHome $dshHome
        exit 0
    }

    if ($Action -eq 'install' -and $homeInfo.Ambiguous) {
        Show-DshHomeCandidates -Info $homeInfo
        if (Test-Interactive) {
            $ans = Read-Host '  将安装到上表 [选中] 的目录。回车继续，或输入 n 取消'
            if ($ans -match '^\s*[nN]') { Write-Warn2 '已取消，未做任何改动。'; exit 0 }
        } else {
            Write-Warn2 '非交互模式：直接采用上表 [选中] 的目录。'
        }
        Write-Host ''
    }

    if (-not $readOnly) {
        $null = Get-PresetRoot -DshHome $dshHome -Create
    }

    switch ($Action) {
        'list'    { Invoke-LegacyList -PresetRoot $presetRoot }
        'check'   { [void](Invoke-LegacyCheck -DshHome $dshHome -PresetRoot $presetRoot) }
        'dry-run' { Invoke-LegacyInstall -PresetRoot $presetRoot -DryRun }
        'install' {
            Invoke-LegacyInstall -PresetRoot $presetRoot
            Write-Host ''
            [void](Invoke-LegacyCheck -DshHome $dshHome -PresetRoot $presetRoot)
            Write-Host ''
            Write-Warn2 '本机部署不含 0.2.x 新机制；若你的 DSH 实际是 0.2.x，目录安装不会生效 —— 请用 -Deployment 指定部署根目录后重试。'
        }
        'uninstall' {
            if (-not (Invoke-LegacyUninstall -PresetRoot $presetRoot)) {
                Write-Host ''
                Write-Host '  安全闸已拒绝删除，未做任何改动（退出码 3）。' -ForegroundColor DarkGray
                exit 3
            }
        }
    }

    if ($readOnly) { Assert-NoWrite -Root $presetRoot -ExistedBefore $rootExistedBefore }

    exit 0
}
catch {
    Write-Host ''
    Write-Err2 $_.Exception.Message
    Write-Host ''
    Write-Host '  排障：先跑  .\unlock-dsh.ps1 diagnose  看它探测到了什么。' -ForegroundColor DarkGray
    Write-Host '  若问题持续，请把以上完整输出反馈到项目 Issues。' -ForegroundColor DarkGray
    exit 1
}
