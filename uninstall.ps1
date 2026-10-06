#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-web-search-mcp 제거 스크립트.

.DESCRIPTION
  1. 프로파일 cordis.patch.yml 에서 관리 블록 제거 (원본은 백업)
  2. <DSH_HOME>\AGENTS.md 에서 관리 섹션 제거
  3. <DSH_HOME>\mcp\dsh-web-search.py 삭제 (디렉터리가 비면 함께 삭제)

  ~/.dsh/web-search.json 과 .credentials.yaml 은 사용자 자산이므로 건드리지 않는다.

.PARAMETER DshHome
  DSH 홈 디렉터리. 기본값: $env:DSH_HOME, 없으면 ~/.dsh

.PARAMETER Profile
  프로파일 이름. 생략하면 자동 탐지.

.PARAMETER DryRun
  실제로 삭제하지 않고 계획만 출력.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [string]$Profile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$BeginMarker = '# >>> dsh-web-search-mcp managed block (do not edit) >>>'
$EndMarker = '# <<< dsh-web-search-mcp managed block <<<'
$AgentsBegin = '<!-- dsh-web-search-mcp:begin -->'
$AgentsEnd = '<!-- dsh-web-search-mcp:end -->'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "    - $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }

function Get-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Set-TextFile([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Remove-MarkedBlock {
    param([string[]]$Lines, [string]$Begin, [string]$End)
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if ($t -eq $Begin) { $inside = $true; continue }
        if ($t -eq $End) { $inside = $false; continue }
        if (-not $inside) { $out.Add($line) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- DSH 홈/프로파일
if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $HOME '.dsh' }
}
$DshHome = [System.IO.Path]::GetFullPath($DshHome)
if (-not (Test-Path -LiteralPath $DshHome)) {
    Write-Host "DSH 홈을 찾을 수 없습니다: $DshHome" -ForegroundColor Red
    exit 1
}
Write-Step "DSH 홈: $DshHome"

$ProfilesRoot = Join-Path $DshHome 'profiles'
if ($Profile) {
    $ProfileDir = Join-Path $ProfilesRoot $Profile
} else {
    $candidates = @()
    if (Test-Path -LiteralPath $ProfilesRoot) {
        $candidates = Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cordis.patch.yml') }
    }
    if ($candidates.Count -eq 1) { $ProfileDir = $candidates[0].FullName }
    elseif ($candidates.Count -eq 0) { $ProfileDir = $null }
    else {
        Write-Host '프로파일이 여러 개입니다. -Profile 로 지정하세요:' -ForegroundColor Red
        $candidates | ForEach-Object { Write-Info $_.Name }
        exit 1
    }
}

# ---------------------------------------------------------------- 1. 패치 파일
$PatchPath = if ($ProfileDir) { Join-Path $ProfileDir 'cordis.patch.yml' } else { $null }
if ($PatchPath -and (Test-Path -LiteralPath $PatchPath)) {
    Write-Step "프로파일 패치 정리: $PatchPath"
    $text = Get-TextFile $PatchPath
    $lines = @($text -split "`r?`n")
    $newLines = Remove-MarkedBlock -Lines $lines -Begin $BeginMarker -End $EndMarker
    if ($newLines.Count -eq $lines.Count) {
        Write-Info '관리 블록이 없습니다(이미 제거됨).'
    } elseif ($DryRun) {
        Write-Info '[DryRun] 관리 블록을 제거합니다.'
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $PatchPath -Destination "$PatchPath.bak-$stamp" -Force
        $result = New-Object System.Collections.Generic.List[string]
        $result.AddRange([string[]]$newLines)
        while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim().Length -eq 0) {
            $result.RemoveAt($result.Count - 1)
        }
        $outText = if ($result.Count -gt 0) { ($result.ToArray() -join "`r`n") + "`r`n" } else { '' }
        Set-TextFile -Path $PatchPath -Text $outText
        Write-Ok '관리 블록 제거 (백업 생성)'
    }
} else {
    Write-Info '프로파일 패치 파일을 찾지 못했습니다(건너뜀).'
}

# ---------------------------------------------------------------- 2. AGENTS.md
$AgentsPath = Join-Path $DshHome 'AGENTS.md'
if (Test-Path -LiteralPath $AgentsPath) {
    Write-Step "AGENTS.md 정리: $AgentsPath"
    $text = Get-TextFile $AgentsPath
    $lines = @($text -split "`r?`n")
    $newLines = Remove-MarkedBlock -Lines $lines -Begin $AgentsBegin -End $AgentsEnd
    if ($newLines.Count -eq $lines.Count) {
        Write-Info '관리 섹션이 없습니다.'
    } elseif ($DryRun) {
        Write-Info '[DryRun] 관리 섹션을 제거합니다.'
    } else {
        $result = New-Object System.Collections.Generic.List[string]
        $result.AddRange([string[]]$newLines)
        while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim().Length -eq 0) {
            $result.RemoveAt($result.Count - 1)
        }
        if ($result.Count -eq 0 -or (($result.ToArray() -join '').Trim().Length -eq 0)) {
            Remove-Item -LiteralPath $AgentsPath -Force
            Write-Ok 'AGENTS.md 삭제 (남은 내용 없음)'
        } else {
            Set-TextFile -Path $AgentsPath -Text (($result.ToArray() -join "`r`n") + "`r`n")
            Write-Ok '관리 섹션 제거'
        }
    }
} else {
    Write-Info 'AGENTS.md 가 없습니다(건너뜀).'
}

# ---------------------------------------------------------------- 3. 서버 스크립트
$McpDir = Join-Path $DshHome 'mcp'
$TargetScript = Join-Path $McpDir 'dsh-web-search.py'
if (Test-Path -LiteralPath $TargetScript) {
    Write-Step "서버 스크립트 삭제: $TargetScript"
    if ($DryRun) {
        Write-Info '[DryRun] 삭제 예정'
    } else {
        Remove-Item -LiteralPath $TargetScript -Force
        Write-Ok '삭제 완료'
        $left = Get-ChildItem -LiteralPath $McpDir -Force -ErrorAction SilentlyContinue
        if (-not $left -or $left.Count -eq 0) {
            Remove-Item -LiteralPath $McpDir -Force
            Write-Ok '빈 mcp 디렉터리 삭제'
        }
    }
} else {
    Write-Info '설치된 서버 스크립트가 없습니다(건너뜀).'
}

Write-Host ''
Write-Host '제거 완료. DSH를 재시작하면 반영됩니다.' -ForegroundColor Yellow
Write-Host '참고: ~/.dsh/web-search.json 과 .credentials.yaml 은 그대로 유지됩니다.' -ForegroundColor Gray