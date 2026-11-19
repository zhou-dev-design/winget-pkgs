#Requires -Version 5.1
<#
ci-bump.ps1 —— 在 GitHub Actions 里跑：只跟 VS Code 和 DeepSeek Harness 两个包

工作目录是仓库根（checkout 出来的那份）。有新版本才动文件，没变化不产生提交。
环境变量：
  GITHUB_TOKEN  可选，用于提高 GitHub API 限额（Actions 里自带）
  REPO_ROOT     仓库根，默认当前目录

退出码：0 一切正常（含"没有新版本"）；非 0 表示出错，工作流会标红。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = $(if ($env:REPO_ROOT) { $env:REPO_ROOT } else { (Get-Location).Path }),
    [string]$Only,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$script:Upstream = 'microsoft/winget-pkgs'
$script:Token = $env:GITHUB_TOKEN

function Write-Head([string]$t) { Write-Host "`n== $t" }
function Write-Ok([string]$t) { Write-Host "  [ok] $t" }
function Write-Warn2([string]$t) { Write-Host "  [!] $t" }
function Write-Dim([string]$t) { Write-Host "  $t" }

# ---------------------------------------------------------------- 通用

function Get-NatKey([string]$s) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($m in [regex]::Matches($s, '\d+|\D+')) {
        if ($m.Value -match '^\d') { [void]$sb.Append($m.Value.PadLeft(12, '0')) }
        else { [void]$sb.Append($m.Value.ToLower()) }
    }
    $sb.ToString()
}

function Sort-Versions($v) { @($v | Where-Object { $_ } | Sort-Object { Get-NatKey $_ }) }

function Test-VersionName([string]$name) { $name -match '\d' -and $name -notmatch '^(CLI|Insiders)$' }

function Get-Json([string]$uri) {
    $h = @{ 'User-Agent' = 'winget-bump'; 'Accept' = 'application/vnd.github+json' }
    # token 只发给 GitHub API，别把 Actions 凭据漏给 code.visualstudio.com 之类的第三方
    if ($script:Token -and $uri -like 'https://api.github.com/*') { $h['Authorization'] = "Bearer $script:Token" }
    $r = Invoke-RestMethod -Uri $uri -Headers $h -TimeoutSec 90
    if ($null -eq $r) { return }
    # Invoke-RestMethod 不枚举顶层数组，不摊平会被当成一个元素
    foreach ($x in $r) { $x }
}

function Get-IdParts([string]$id) {
    $i = $id.IndexOf('.')
    [pscustomobject]@{
        Id      = $id
        RelPath = "manifests/$($id.Substring(0,1).ToLower())/$($id.Substring(0,$i))/$($id.Substring($i+1))"
    }
}

function Get-RepoVersions([string]$id) {
    $p = Get-IdParts $id
    $dir = Join-Path $RepoRoot $p.RelPath
    if (-not (Test-Path $dir)) { return @() }
    Sort-Versions (@(Get-ChildItem -LiteralPath $dir -Directory |
                     Where-Object { Test-VersionName $_.Name } | ForEach-Object { $_.Name }))
}

# ---------------------------------------------------------------- 清单改写

function Save-Manifest([string]$path, [string]$text) {
    $text = $text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function Ensure-TrailingNewline([string]$path) {
    $t = [IO.File]::ReadAllText($path)
    if ($t.Length -and -not $t.EndsWith("`n")) { Save-Manifest $path ($t + "`n") }
}

function Set-PackageVersion([string]$path, [string]$newVer) {
    $text = Get-Content -LiteralPath $path -Raw
    $hadQuote = $text -match '(?m)^PackageVersion:\s*"'
    $needsQuote = $newVer -match '^\d+(\.\d+)?$'      # 26.06 会被 YAML 当浮点，1.147.0 不会
    $value = if ($hadQuote -or $needsQuote) { '"' + $newVer + '"' } else { $newVer }
    $text = [regex]::Replace($text, '(?m)^PackageVersion:.*$', "PackageVersion: $value")
    Save-Manifest $path $text
}

function Update-ReleaseNotesUrl([string]$path, [string]$oldVer, [string]$newVer) {
    $lines = @(Get-Content -LiteralPath $path)
    $hit = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(ReleaseNotesUrl:\s*)(\S+)\s*$') {
            $lines[$i] = $matches[1] + ($matches[2] -replace [regex]::Escape($oldVer), $newVer)
            $hit = $true
        }
    }
    if ($hit) { Save-Manifest $path ($lines -join "`n") }
}

function Convert-VersionInUrl([string]$url, [string]$oldVer, [string]$newVer, [string]$oldC, [string]$newC) {
    $url = $url -replace [regex]::Escape($oldVer), $newVer
    $i = $url.LastIndexOf('/')
    if ($i -lt 0) { return $url }
    $head = $url.Substring(0, $i + 1); $tail = $url.Substring($i + 1)
    if ($oldC -and $newC -and $oldC -ne $newC) { $tail = $tail -replace [regex]::Escape($oldC), $newC }
    $head + $tail
}

# 安装项选择器：arch[@scope][:type]
function Select-InstallerSpec {
    param($Specs, [string]$Arch, [string]$Scope, [string]$Type)
    $c = @($Specs | Where-Object {
            $_.Arch -eq $Arch -and
            (-not $_.Scope -or -not $Scope -or $_.Scope -eq $Scope) -and
            (-not $_.Type -or -not $Type -or $_.Type -eq $Type)
        })
    if (-not $c) { return $null }
    $c = @($c | Sort-Object -Property @{ Expression = { $n = 0; if ($_.Scope) { $n += 2 }; if ($_.Type) { $n += 2 }; $n } } -Descending)
    $c[0]
}

function Update-InstallerManifest {
    param([string]$Path, [string]$OldVer, [string]$NewVer, $Specs, [string]$ReleaseDate)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Get-Content -LiteralPath $Path)) { $lines.Add($l) }

    $oldC = ($OldVer -replace '[^\d]', ''); $newC = ($NewVer -replace '[^\d]', '')
    $inInstallers = $false; $item = $null
    $items = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^Installers:\s*$') { $inInstallers = $true; continue }
        if ($inInstallers -and $line -match '^[A-Za-z]') { $inInstallers = $false }

        if ($inInstallers) {
            if ($line -match '^-\s*Architecture:\s*(\S+)') {
                if ($item) { $items.Add($item) }
                $item = [pscustomobject]@{ Arch = $matches[1].ToLower(); Scope = ''; Type = ''; UrlIndex = -1; ShaIndex = -1; Url = $null; Spec = $null }
                continue
            }
            if ($line -match '^(\s+)InstallerType:\s*(\S+)\s*$') { if ($item) { $item.Type = $matches[2].ToLower() }; continue }
            if ($line -match '^(\s+)Scope:\s*(\S+)\s*$') { if ($item) { $item.Scope = $matches[2].ToLower() }; continue }
            if ($line -match '^(\s*)InstallerUrl:\s*(\S+)\s*$') {
                $indent = $matches[1]; $url = $matches[2]
                $spec = if ($item) { Select-InstallerSpec $Specs $item.Arch $item.Scope $item.Type } else { $null }
                if ($spec) { $url = $spec.Url }
                else { $url = Convert-VersionInUrl $url $OldVer $NewVer $oldC $newC }
                $lines[$i] = "${indent}InstallerUrl: $url"
                if ($item) { $item.UrlIndex = $i; $item.Url = $url; $item.Spec = $spec }
                continue
            }
            if ($line -match '^(\s+)InstallerSha256:') { if ($item) { $item.ShaIndex = $i }; continue }
            if ($line -match '^(\s+)DisplayVersion:\s*(.+?)\s*$') {
                if ($matches[2].Trim('"') -eq $OldVer) { $lines[$i] = "$($matches[1])DisplayVersion: $NewVer" }
                continue
            }
            if ($line -match '^(\s*)ProductCode:') {
                if ($oldC -and $newC -and $oldC -ne $newC) { $lines[$i] = $line -replace [regex]::Escape($oldC), $newC }
                continue
            }
        }

        if ($ReleaseDate -and $line -match '^ReleaseDate:') { $lines[$i] = "ReleaseDate: $ReleaseDate" }
    }
    if ($item) { $items.Add($item) }

    foreach ($it in $items) {
        if ($it.UrlIndex -lt 0) { continue }
        $sha = if ($it.Spec -and $it.Spec.Sha256) { $it.Spec.Sha256 } else { $null }
        if (-not $sha) { throw "安装项 $($it.Arch)/$($it.Scope)/$($it.Type) 没拿到哈希：$($it.Url)" }
        if ($it.ShaIndex -ge 0) {
            $lines[$it.ShaIndex] = [regex]::Replace($lines[$it.ShaIndex], 'InstallerSha256:.*', "InstallerSha256: $sha")
        }
    }

    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

# 用仓库里已有的最新版当基底，生成新版本目录
function New-VersionFromBase {
    param([string]$Id, [string]$Base, [string]$Version, $Specs, [string]$ReleaseDate)

    $p = Get-IdParts $Id
    $baseDir = Join-Path $RepoRoot "$($p.RelPath)/$Base"
    if (-not (Test-Path $baseDir)) { throw "基底目录不存在：$baseDir" }

    $dest = Join-Path $RepoRoot "$($p.RelPath)/$Version"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $baseDir '*') -Destination $dest -Recurse -Force

    $installerYaml = $null
    foreach ($f in (Get-ChildItem -LiteralPath $dest -File)) {
        Set-PackageVersion $f.FullName $Version
        Update-ReleaseNotesUrl $f.FullName $Base $Version
        if ($f.Name -like '*.installer.yaml') { $installerYaml = $f.FullName }
    }
    if (-not $installerYaml) { throw "$Id 缺 *.installer.yaml" }
    Update-InstallerManifest -Path $installerYaml -OldVer $Base -NewVer $Version -Specs $Specs -ReleaseDate $ReleaseDate
    foreach ($f in (Get-ChildItem -LiteralPath $dest -File)) { Ensure-TrailingNewline $f.FullName }

    Write-Ok "生成 $($p.RelPath)/$Version（基底 $Base）"
    $p.RelPath
}

function Test-Manifest([string]$Id, [string]$Version) {
    $p = Get-IdParts $Id
    $dir = Join-Path $RepoRoot "$($p.RelPath)/$Version"
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg) { Write-Warn2 'runner 上找不到 winget，跳过 validate'; return $true }
    $out = & winget validate --manifest $dir 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok 'winget validate 通过'; return $true }
    Write-Warn2 "winget validate 失败：`n$($out | Out-String)"
    return $false
}

# ---------------------------------------------------------------- 探测

function Get-VsCodeRelease {
    $plats = [ordered]@{
        'x64@user' = 'win32-x64-user'; 'x64@machine' = 'win32-x64'
        'arm64@user' = 'win32-arm64-user'; 'arm64@machine' = 'win32-arm64'
    }
    $specs = @(); $ver = $null; $stamp = $null
    foreach ($sel in $plats.Keys) {
        $j = Get-Json "https://update.code.visualstudio.com/api/update/$($plats[$sel])/stable/latest"
        if (-not $ver) { $ver = $j.productVersion; $stamp = $j.timestamp }
        if ($j.productVersion -ne $ver) { Write-Warn2 "通道 $($plats[$sel]) 还是 $($j.productVersion)，本轮跳过"; return $null }
        $arch = ($sel -split '@')[0]; $scope = ($sel -split '@')[1]
        $specs += [pscustomobject]@{ Arch = $arch; Scope = $scope; Type = ''; Url = $j.url; Sha256 = $j.sha256hash }
    }
    [pscustomobject]@{
        Version     = $ver
        ReleaseDate = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$stamp).UtcDateTime.ToString('yyyy-MM-dd')
        Specs       = $specs
    }
}

# 下载安装包算 SHA256（带重试）；文件不在就返回 $null，调用方按"等上传"处理
function Get-UrlSha256([string]$url) {
    for ($try = 1; $try -le 3; $try++) {
        try {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "dl-$([guid]::NewGuid().ToString('N')).bin"
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 3600
            $sha = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $sha
        } catch {
            Write-Warn2 "下载失败（第 $try 次）：$($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
    return $null
}

function Get-GitHubRelease($pkg) {
    $raw = @(Get-Json "https://api.github.com/repos/$($pkg.GitHub)/releases?per_page=10")
    $rel = @($raw | Where-Object { -not $_.draft })
    if (-not $rel) { throw "$($pkg.GitHub) 没有非草稿 release" }
    $r = @($rel | Sort-Object { $_.published_at } -Descending)[0]

    $ver = $r.tag_name
    if ($pkg.TagPrefix) { $ver = $ver.Substring($pkg.TagPrefix.Length) }

    $specs = @()
    foreach ($sel in $pkg.Installers.Keys) {
        $url = $pkg.Installers[$sel].Replace('{version}', $ver)
        $head = $null
        try { $head = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 60 } catch { }
        if (-not $head) { return [pscustomobject]@{ Version = $ver; Pending = $url } }

        $arch = ($sel -split '@')[0]
        $scope = if ($sel -match '@') { ($sel -split '@')[1] } else { '' }
        # 哈希先不算：286MB 不能每小时都下一遍，等确认要发版了再下
        $specs += [pscustomobject]@{ Arch = $arch; Scope = $scope; Type = ''; Url = $url; Sha256 = $null }
    }
    [pscustomobject]@{
        Version     = $ver
        ReleaseDate = ([DateTimeOffset]$r.published_at).UtcDateTime.ToString('yyyy-MM-dd')
        Specs       = $specs
    }
}

# ---------------------------------------------------------------- 主流程

$packages = @(
    @{ Id = 'Microsoft.VisualStudioCode'; Source = 'vscode' }
    @{
        Id         = 'DeepSeek.DeepSeekHarnessDesktop'
        Source     = 'github'
        GitHub     = 'deepseek-ai/deepseek-harness'
        TagPrefix  = 'dsh-v'
        Installers = [ordered]@{
            'x64@user' = 'https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-{version}-win-x64.exe'
        }
    }
)

$bumped = @()
$script:failed = $false
foreach ($pkg in $packages) {
    if ($Only -and $Only -ne $pkg.Id) { continue }
    Write-Head "$($pkg.Id)  [$($pkg.Source)]"
    try {
        $rel = switch ($pkg.Source) {
            'vscode' { Get-VsCodeRelease }
            'github' { Get-GitHubRelease $pkg }
        }
        if (-not $rel) { continue }

        if ($rel.Pending) {
            Write-Warn2 "版本 $($rel.Version) 已发布但安装包还没上传，本轮跳过：$($rel.Pending)"
            continue
        }

        $repoVers = @(Get-RepoVersions $pkg.Id)
        $have = if ($repoVers) { $repoVers[-1] } else { '' }
        Write-Dim "仓库里 $($have)  上游探测 $($rel.Version)"

        if ($have -and (Get-NatKey $rel.Version) -le (Get-NatKey $have)) { Write-Ok '已是最新'; continue }
        if (-not $have) { Write-Warn2 "仓库里没有这个包，先手工放一份基底再自动跟版本"; continue }

        # 确认要发版了，才去下载安装包算哈希
        $missing = $false
        foreach ($sp in $rel.Specs) {
            if ($sp.Sha256) { continue }
            if ($DryRun) { Write-Dim "DryRun：跳过哈希计算 $($sp.Url)"; continue }
            Write-Dim "下载并计算哈希：$($sp.Url)"
            $sp.Sha256 = Get-UrlSha256 $sp.Url
            if (-not $sp.Sha256) { Write-Warn2 "文件取不到，本轮跳过：$($sp.Url)"; $missing = $true }
        }
        if ($missing) { continue }

        $relPath = New-VersionFromBase -Id $pkg.Id -Base $have -Version $rel.Version -Specs $rel.Specs -ReleaseDate $rel.ReleaseDate
        if (-not (Test-Manifest $pkg.Id $rel.Version)) { throw "validate 没过，不提交" }
        $bumped += [pscustomobject]@{ Id = $pkg.Id; Version = $rel.Version; RelPath = $relPath }
    } catch {
        Write-Warn2 "出错：$($_.Exception.Message)"
        $script:failed = $true
    }
}

# 没变化就不提交；有变化一个包一个 commit
foreach ($b in $bumped) {
    $msg = "New version: $($b.Id) version $($b.Version)"
    if ($DryRun) { Write-Dim "DryRun：git add $($b.RelPath)  /  commit -m `"$msg`""; continue }
    & git -C $RepoRoot add -- $b.RelPath
    if ($LASTEXITCODE -ne 0) { throw "git add 失败：$($b.RelPath)" }

    # 安全网：仓库有上百万个文件，万一稀疏检出把索引搞没了，暂存区会出现海量删除
    $num = @(& git -C $RepoRoot diff --cached --numstat)
    $dels = @($num | Where-Object { $p = $_ -split "`t"; $p.Count -ge 2 -and $p[1] -ne '0' })
    if ($dels.Count -gt 0) {
        & git -C $RepoRoot reset -q
        throw "暂存区出现 $($dels.Count) 个删除（如 $($dels[0])），疑似稀疏检出丢了索引，已中止"
    }

    & git -C $RepoRoot commit -q -m $msg
    if ($LASTEXITCODE -ne 0) { throw "git commit 失败：$msg" }
    Write-Ok "已提交：$msg"
}

Write-Head '汇总'
Write-Host "  更新 $(@($bumped).Count) 个包：$((@($bumped) | ForEach-Object { "$($_.Id) $($_.Version)" }) -join '，')"
if ($script:failed) { exit 1 }
exit 0
