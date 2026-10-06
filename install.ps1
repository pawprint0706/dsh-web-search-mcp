#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-web-search-mcp 설치 스크립트 (멱등).

.DESCRIPTION
  DSH(DeepSeek Harness)에 OpenRouter 기반 웹 검색 MCP 서버를 설치한다.

  1. server/dsh-web-search.py 를 <DSH_HOME>\mcp\ 로 복사
  2. <DSH_HOME>\AGENTS.md 에 "MCP 검색 도구를 사용하라"는 관리 섹션 추가
  3. <DSH_HOME>\profiles\<profile>\cordis.patch.yml 에 관리 블록 추가
       - 내장 web-search-deepseek 비활성화 (OpenRouter에서 동작하지 않음)
       - @deepseek-ai/dsh-mcp-client 행 삽입 (MCP stdio 서버 등록)

  재실행해도 안전하다: 관리 블록은 통째로 교체되고, 이전에 손으로 넣은
  동일 id 항목(mcp-dsh-web-search / web-search-deepseek)은 중복 등록을 막기 위해
  제거된다. 수정 전 원본은 타임스탬프 백업으로 남는다.

.PARAMETER DshHome
  DSH 홈 디렉터리. 기본값: $env:DSH_HOME, 없으면 ~/.dsh

.PARAMETER Profile
  프로파일 이름(예: desktop). 생략하면 cordis.patch.yml 을 가진 프로파일을 자동 탐지한다.

.PARAMETER PythonPath
  MCP 서버를 실행할 python.exe 경로. 생략하면 DSH 번들 런타임 → PATH 순으로 탐색한다.

.PARAMETER DryRun
  파일을 쓰지 않고 수행할 작업만 출력한다.

.PARAMETER SkipVerify
  설치 후 자체 점검(verify.ps1)을 건너뛴다.

.PARAMETER NoAgents
  AGENTS.md 관리 섹션을 설치하지 않는다.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
  .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [string]$Profile,
    [string]$PythonPath,
    [switch]$DryRun,
    [switch]$SkipVerify,
    [switch]$NoAgents
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 상수
$ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SourceScript = Join-Path $ProjectRoot 'server\dsh-web-search.py'
$SourceAgents = Join-Path $ProjectRoot 'templates\AGENTS.md'

$BeginMarker = '# >>> dsh-web-search-mcp managed block (do not edit) >>>'
$EndMarker = '# <<< dsh-web-search-mcp managed block <<<'
$AgentsBegin = '<!-- dsh-web-search-mcp:begin -->'
$AgentsEnd = '<!-- dsh-web-search-mcp:end -->'
$McpRowId = 'mcp-dsh-web-search'
$ProviderRowId = 'web-search-deepseek'

# ---------------------------------------------------------------- 출력 헬퍼
function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "    - $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "    [X] $Text" -ForegroundColor Red }

# ---------------------------------------------------------------- 파일 헬퍼
function Get-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Set-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)   # BOM 없음
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# YAML 목록 항목을 id 기준으로 제거한다(들여쓰기 깊이 무관).
function Remove-YamlListItemById {
    param([string[]]$Lines, [string]$Id)
    $pattern = '^(\s*)-\s*id:\s*["'']?' + [regex]::Escape($Id) + '["'']?\s*$'
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Lines.Count) {
        $m = [regex]::Match($Lines[$i], $pattern)
        if (-not $m.Success) { $out.Add($Lines[$i]); $i++; continue }
        $indent = $m.Groups[1].Value.Length
        $i++   # id 줄 자체를 건너뛴다
        while ($i -lt $Lines.Count) {
            $line = $Lines[$i]
            if ($line.Trim().Length -eq 0) { $i++; continue }
            $lineIndent = $line.Length - $line.TrimStart().Length
            if ($lineIndent -lt $indent) { break }
            if ($lineIndent -eq $indent -and $line.TrimStart().StartsWith('- ')) { break }
            $i++
        }
    }
    return $out.ToArray()
}

# 마커 사이의 관리 블록을 제거한다.
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

# 자식이 모두 제거되어 빈 껍데기만 남은 `- insert:` 항목을 제거한다.
# (삽입 행을 id로 지운 뒤 부모 insert: 만 남으면 YAML상 null이 되어 로더가 오류를 낼 수 있다.)
function Remove-EmptyInsertLists {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = [regex]::Match($Lines[$i], '^(\s*)-\s*insert:\s*$')
        if (-not $m.Success) { $out.Add($Lines[$i]); continue }
        $indent = $m.Groups[1].Value.Length
        $j = $i + 1
        while ($j -lt $Lines.Count -and $Lines[$j].Trim().Length -eq 0) { $j++ }
        $hasChild = $false
        if ($j -lt $Lines.Count) {
            $childIndent = $Lines[$j].Length - $Lines[$j].TrimStart().Length
            if ($childIndent -gt $indent -and $Lines[$j].TrimStart().StartsWith('- ')) { $hasChild = $true }
        }
        if ($hasChild) { $out.Add($Lines[$i]) }
    }
    return $out.ToArray()
}

function Test-AsarContains {
    param([string]$AsarPath, [string]$Needle, [int]$ScanBytes = 8388608)
    try {
        $stream = [System.IO.File]::OpenRead($AsarPath)
        try {
            $size = [int][Math]::Min($ScanBytes, $stream.Length)
            $buffer = New-Object byte[] $size
            $read = $stream.Read($buffer, 0, $size)
        } finally { $stream.Dispose() }
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($buffer, 0, $read)
        return $text.Contains($Needle)
    } catch { return $false }
}

# ---------------------------------------------------------------- 1. DSH 홈
Write-Step 'DSH 홈 확인'
if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
    else { $DshHome = Join-Path $HOME '.dsh' }
}
$DshHome = [System.IO.Path]::GetFullPath($DshHome)
if (-not (Test-Path -LiteralPath $DshHome)) {
    Write-Err2 "DSH 홈을 찾을 수 없습니다: $DshHome"
    Write-Info 'DSH를 최소 한 번 실행한 뒤 다시 시도하거나 -DshHome 으로 지정하세요.'
    exit 1
}
Write-Ok "DSH 홈: $DshHome"

# ---------------------------------------------------------------- 2. 프로파일
Write-Step '프로파일 확인'
$ProfilesRoot = Join-Path $DshHome 'profiles'
if ($Profile) {
    $ProfileDir = Join-Path $ProfilesRoot $Profile
    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        Write-Err2 "프로파일 디렉터리가 없습니다: $ProfileDir"
        exit 1
    }
} else {
    $candidates = @()
    if (Test-Path -LiteralPath $ProfilesRoot) {
        $candidates = Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cordis.patch.yml') }
    }
    if ($candidates.Count -eq 1) {
        $ProfileDir = $candidates[0].FullName
    } elseif ($candidates.Count -eq 0) {
        Write-Err2 "cordis.patch.yml 을 가진 프로파일을 찾지 못했습니다: $ProfilesRoot"
        Write-Info 'DSH를 최소 한 번 실행한 뒤 다시 시도하세요.'
        exit 1
    } else {
        Write-Err2 '프로파일이 여러 개입니다. -Profile 로 지정하세요:'
        $candidates | ForEach-Object { Write-Info $_.Name }
        exit 1
    }
}
$ProfileName = Split-Path -Leaf $ProfileDir
$PatchPath = Join-Path $ProfileDir 'cordis.patch.yml'
Write-Ok "프로파일: $ProfileName"
Write-Info "패치 파일: $PatchPath"

# ---------------------------------------------------------------- 3. python
Write-Step 'python 실행 파일 확인'
# 주의: 네이티브 명령 인자는 PowerShell이 따옴표를 제거하므로 python 코드에
# 인용부호를 쓰지 않는다. --version 출력을 파싱해 버전을 판정한다.
function Test-Python([string]$Exe, [string[]]$PrefixArgs = @()) {
    # 네이티브 명령의 stderr 는 Stop 에서 종료 오류로 승격되므로 구간적으로 낮춘다.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& $Exe @PrefixArgs '--version' 2>&1 | Out-String)
        if ($raw -match 'Python\s+(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 8)) { return "$major.$minor" }
        }
    } catch { } finally { $ErrorActionPreference = $prevEap }
    return $null
}

$PythonExe = $null
$PythonArgs = @()
$PythonVer = $null

if ($PythonPath) {
    if (Test-Path -LiteralPath $PythonPath) {
        $PythonVer = Test-Python $PythonPath
        if ($PythonVer) { $PythonExe = $PythonPath }
    }
    if (-not $PythonExe) { Write-Err2 "-PythonPath 가 유효한 python 3.8+ 가 아닙니다: $PythonPath"; exit 1 }
} else {
    # 3-1) DSH 번들 런타임 (가장 안정적)
    $RuntimesRoot = Join-Path $DshHome 'dsh-runtimes'
    if (Test-Path -LiteralPath $RuntimesRoot) {
        $bundled = Get-ChildItem -LiteralPath $RuntimesRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'dependencies\python\python.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending
        foreach ($candidate in $bundled) {
            $v = Test-Python $candidate
            if ($v) { $PythonExe = $candidate; $PythonVer = $v; break }
        }
    }
    # 3-2) PATH
    if (-not $PythonExe) {
        foreach ($name in @('python', 'python3')) {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue
            if ($cmd) {
                $v = Test-Python $cmd.Source
                if ($v) { $PythonExe = $cmd.Source; $PythonVer = $v; break }
            }
        }
    }
    if (-not $PythonExe) {
        Write-Err2 'python 3.8+ 를 찾지 못했습니다.'
        Write-Info 'DSH 번들 런타임이 없다면 python을 설치하거나 -PythonPath 로 지정하세요.'
        exit 1
    }
}
Write-Ok "python: $PythonExe (v$PythonVer)"

# ---------------------------------------------------------------- 4. 사전 점검
Write-Step '사전 점검'

# 4-1) 소스 파일
foreach ($f in @($SourceScript)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Err2 "필수 파일이 없습니다: $f"; exit 1 }
}
Write-Ok '서버 스크립트 확인'

# 4-2) OpenRouter 자격증명
$CredPath = Join-Path $DshHome '.credentials.yaml'
$HasKey = $false
if (Test-Path -LiteralPath $CredPath) {
    $credText = Get-TextFile $CredPath
    $HasKey = [bool]([regex]::IsMatch($credText, '(?m)^\s*OPENROUTER_API_KEY\s*:\s*\S+'))
}
if ($HasKey) {
    Write-Ok 'OpenRouter API 키 확인 (.credentials.yaml)'
} else {
    Write-Warn2 'OpenRouter API 키를 찾지 못했습니다.'
    Write-Info 'DSH 설정에서 OpenRouter 제공자에 API 키를 등록하세요(등록하면 .credentials.yaml 의 refs 에 저장됩니다).'
    Write-Info '또는 ~/.dsh/web-search.json 에 "api_key" 를 직접 넣거나 DSH_WEB_SEARCH_API_KEY 환경변수를 사용할 수 있습니다.'
}

# 4-3) DSH 앱 번들에 MCP 클라이언트가 포함되어 있는지
$asarCandidates = @()
$running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running -and $running.Path) {
    $asarCandidates += (Join-Path (Split-Path -Parent $running.Path) 'resources\app.asar')
}
$asarCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\app.asar')
$asarCandidates += (Join-Path ${env:ProgramFiles} 'DeepSeek Harness\resources\app.asar')

$asarFound = $null
foreach ($a in $asarCandidates) {
    if ($a -and (Test-Path -LiteralPath $a)) { $asarFound = $a; break }
}
if ($asarFound) {
    if (Test-AsarContains -AsarPath $asarFound -Needle 'dsh-mcp-client') {
        Write-Ok 'DSH에 내장 MCP 클라이언트 확인 (dsh-mcp-client)'
    } else {
        Write-Warn2 'app.asar 에서 dsh-mcp-client 를 찾지 못했습니다.'
        Write-Info '이 DSH 버전이 MCP를 지원하지 않으면 MCP 행은 로드되지 않습니다.'
    }
} else {
    Write-Info 'app.asar 를 찾지 못해 MCP 지원 여부를 확인하지 못했습니다(설치는 계속 진행).'
}

# ---------------------------------------------------------------- 5. 파일 설치
Write-Step '파일 설치'
$TargetScriptDir = Join-Path $DshHome 'mcp'
$TargetScript = Join-Path $TargetScriptDir 'dsh-web-search.py'

$pyYaml = $PythonExe -replace "'", "''"
$scriptYaml = $TargetScript -replace "'", "''"
$dshHomeYaml = $DshHome -replace "'", "''"

$blockTemplate = @'
# >>> dsh-web-search-mcp managed block (do not edit) >>>
# install.ps1 이 생성/관리합니다. 재실행하면 이 블록만 통째로 교체됩니다.
# (1) OpenRouter에서 동작하지 않는 내장 웹 검색 제공자를 비활성화한다.
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  disabled: true
# (2) OpenRouter 네이티브 웹 검색을 MCP stdio 서버로 등록한다.
#     도구 공개 이름: mcp__dsh-web-search__web_search / mcp__dsh-web-search__web_fetch
- insert:
    - id: mcp-dsh-web-search
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: dsh-web-search
        transport: stdio
        command: '__PYTHON__'
        args:
          - '__SCRIPT__'
        # DSH는 자식 프로세스 환경에서 `DSH_*` 이름과 *KEY*/*TOKEN*/*SECRET*/*PASSWORD*
        # 이름을 제거한다(scrubbedParentEnv). 그래서 DSH_HOME 을 여기서 명시적으로 넘긴다.
        # 이것이 없으면 서버가 ~/.dsh 로 폴백해, -DshHome 으로 다른 홈을 지정한 설치에서
        # 자격증명과 설정 파일을 찾지 못한다.
        env:
          DSH_HOME: '__DSHHOME__'
        # 클라이언트 타임아웃은 서버 자체 타임아웃(검색 120s)보다 넉넉해야 한다.
        # 두 값이 같으면 클라이언트가 먼저 끊어 서버 오류를 보지 못한다.
        toolCallTimeoutMs: 180000
# <<< dsh-web-search-mcp managed block <<<
'@
$managedBlock = $blockTemplate.Replace('__PYTHON__', $pyYaml).Replace('__SCRIPT__', $scriptYaml).Replace('__DSHHOME__', $dshHomeYaml)

# 5-1) 서버 스크립트
$scriptText = Get-TextFile $SourceScript
if ($DryRun) {
    Write-Info "[DryRun] 복사: $SourceScript -> $TargetScript"
} else {
    Set-TextFile -Path $TargetScript -Text $scriptText
    Write-Ok "서버 스크립트 설치: $TargetScript"
}

# 5-2) 프로파일 패치
$patchText = Get-TextFile $PatchPath
if ($null -eq $patchText) { $patchText = '' }
$patchLines = @($patchText -split "`r?`n")
if ($patchLines.Count -eq 1 -and $patchLines[0] -eq '') { $patchLines = @() }

$before = $patchLines.Count
$patchLines = Remove-MarkedBlock -Lines $patchLines -Begin $BeginMarker -End $EndMarker
$patchLines = Remove-YamlListItemById -Lines $patchLines -Id $McpRowId
$patchLines = Remove-YamlListItemById -Lines $patchLines -Id $ProviderRowId
$patchLines = Remove-EmptyInsertLists -Lines $patchLines
$removed = $before - $patchLines.Count

$result = New-Object System.Collections.Generic.List[string]
$result.AddRange([string[]]$patchLines)
while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim().Length -eq 0) {
    $result.RemoveAt($result.Count - 1)
}
if ($result.Count -gt 0) { $result.Add('') }
$result.AddRange([string[]]($managedBlock -split "`r?`n"))
$newPatchText = ($result.ToArray() -join "`r`n") + "`r`n"

if ($newPatchText -match "`t") {
    Write-Warn2 '결과 YAML에 탭 문자가 있습니다. YAML은 들여쓰기에 탭을 허용하지 않습니다.'
}

if ($DryRun) {
    Write-Info "[DryRun] 패치 파일 수정: $PatchPath (기존 항목 $removed 줄 정리 + 관리 블록 추가)"
    Write-Host ''
    Write-Host '----- 반영될 관리 블록 -----' -ForegroundColor DarkGray
    Write-Host $managedBlock -ForegroundColor DarkGray
} else {
    if (Test-Path -LiteralPath $PatchPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$PatchPath.bak-$stamp"
        Copy-Item -LiteralPath $PatchPath -Destination $backup -Force
        Write-Ok "백업 생성: $(Split-Path -Leaf $backup)"
    }
    Set-TextFile -Path $PatchPath -Text $newPatchText
    Write-Ok "프로파일 패치 갱신 (정리 $removed 줄 + 관리 블록)"
}

# 5-3) AGENTS.md
if (-not $NoAgents) {
    $AgentsPath = Join-Path $DshHome 'AGENTS.md'
    $agentsTemplate = Get-TextFile $SourceAgents
    if ($null -eq $agentsTemplate) {
        Write-Warn2 "템플릿을 찾지 못해 AGENTS.md 를 건너뜁니다: $SourceAgents"
    } else {
        $managedSection = "$AgentsBegin`r`n$($agentsTemplate.Trim())`r`n$AgentsEnd"
        $existing = Get-TextFile $AgentsPath
        if ($null -eq $existing -or $existing.Trim().Length -eq 0) {
            $newAgents = $managedSection + "`r`n"
            $action = '생성'
        } else {
            $lines = @($existing -split "`r?`n")
            $lines = Remove-MarkedBlock -Lines $lines -Begin $AgentsBegin -End $AgentsEnd
            $kept = New-Object System.Collections.Generic.List[string]
            $kept.AddRange([string[]]$lines)
            while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim().Length -eq 0) {
                $kept.RemoveAt($kept.Count - 1)
            }
            if ($kept.Count -gt 0) { $kept.Add('') }
            $kept.AddRange([string[]]($managedSection -split "`r?`n"))
            $newAgents = ($kept.ToArray() -join "`r`n") + "`r`n"
            $action = '갱신'
        }
        if ($DryRun) {
            Write-Info "[DryRun] AGENTS.md $action : $AgentsPath"
        } else {
            Set-TextFile -Path $AgentsPath -Text $newAgents
            Write-Ok "AGENTS.md $action : $AgentsPath"
        }
    }
} else {
    Write-Info 'AGENTS.md 설치는 건너뜀 (-NoAgents)'
}

# ---------------------------------------------------------------- 6. 검증
if (-not $SkipVerify) {
    $verifyScript = Join-Path $ProjectRoot 'verify.ps1'
    if ((Test-Path -LiteralPath $verifyScript) -and -not $DryRun) {
        Write-Step '자체 점검 (MCP stdio 프로브)'
        & $verifyScript -DshHome $DshHome -PythonPath $PythonExe -Profile $ProfileName
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 '자체 점검이 실패했습니다. 위 출력을 확인하세요.'
        }
    }
}

# ---------------------------------------------------------------- 7. 요약
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' 설치 요약' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Info "DSH 홈        : $DshHome"
Write-Info "프로파일      : $ProfileName"
Write-Info "패치 파일     : $PatchPath"
Write-Info "서버 스크립트 : $TargetScript"
Write-Info "python        : $PythonExe"
Write-Info 'MCP 도구      : mcp__dsh-web-search__web_search, mcp__dsh-web-search__web_fetch'
Write-Info '검색 모델     : deepseek/deepseek-v4.1-flash (기본값)'
Write-Host ''
Write-Host '다음 단계:' -ForegroundColor Yellow
Write-Host '  1) DSH를 완전히 종료한 뒤 다시 실행하세요.' -ForegroundColor Yellow
Write-Host '  2) 새 대화에서 웹 검색을 요청하거나, 다음으로 상태를 확인하세요:' -ForegroundColor Yellow
Write-Host "     powershell -ExecutionPolicy Bypass -File `"$(Join-Path $ProjectRoot 'verify.ps1')`" -Search" -ForegroundColor Yellow
Write-Host ''
Write-Host '검색 모델/엔진 변경: ~/.dsh/web-search.json (examples/web-search.json 참고)' -ForegroundColor Gray
Write-Host '제거: uninstall.ps1' -ForegroundColor Gray