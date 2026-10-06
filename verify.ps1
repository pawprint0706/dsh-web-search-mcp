#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-web-search-mcp 사후 점검 스크립트.

.DESCRIPTION
  설치된 MCP 서버 스크립트를 실제로 stdio로 실행해 핸드셰이크와 도구 목록을 확인한다.
  -Search 를 주면 실제 웹 검색까지 1회 수행한다(OpenRouter 호출이 발생하므로 소액 과금).

  확인 항목:
    1. 서버 스크립트/ python 존재
    2. initialize 핸드셰이크 (DSH MCP 클라이언트와 동일한 2025-era 협상)
    3. tools/list (web_search, web_fetch)
    4. DSH 쪽 MCP 자식 프로세스 실행 여부 (= DSH가 실제로 연결했는지)
    5. (선택) tools/call web_search 실제 검색

.PARAMETER DshHome
  DSH 홈 디렉터리. 기본값: $env:DSH_HOME, 없으면 ~/.dsh

.PARAMETER PythonPath
  사용할 python.exe 경로. 생략하면 자동 탐색.

.PARAMETER Profile
  프로파일 이름(예: desktop). 생략하면 cordis.patch.yml 을 가진 프로파일을 자동 탐지한다.

.PARAMETER Search
  실제 웹 검색까지 수행한다(과금 발생).

.PARAMETER Query
  검색어. 기본값: 'DeepSeek Harness'

.EXAMPLE
  .\verify.ps1
.EXAMPLE
  .\verify.ps1 -Search -Query "OpenRouter server tools"
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [string]$PythonPath,
    [string]$Profile,
    [switch]$Search,
    [string]$Query = 'DeepSeek Harness'
)

$ErrorActionPreference = 'Stop'

function Write-Ok([string]$Text) { Write-Host "  [PASS] $Text" -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  - $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }

$failures = 0

# ---------------------------------------------------------------- 경로 해석
if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $HOME '.dsh' }
}
$DshHome = [System.IO.Path]::GetFullPath($DshHome)
$ScriptPath = Join-Path (Join-Path $DshHome 'mcp') 'dsh-web-search.py'
$ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SourceScript = Join-Path $ProjectRoot 'server\dsh-web-search.py'

Write-Host '=== dsh-web-search-mcp 점검 ===' -ForegroundColor Cyan
Write-Info "DSH 홈: $DshHome"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Fail "서버 스크립트가 없습니다: $ScriptPath"
    Write-Info 'install.ps1 을 먼저 실행하세요.'
    exit 1
}
Write-Ok "서버 스크립트: $ScriptPath"

# python 해석
if (-not $PythonPath) {
    $RuntimesRoot = Join-Path $DshHome 'dsh-runtimes'
    if (Test-Path -LiteralPath $RuntimesRoot) {
        $PythonPath = Get-ChildItem -LiteralPath $RuntimesRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'dependencies\python\python.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending |
            Select-Object -First 1
    }
    if (-not $PythonPath) {
        $cmd = Get-Command python -ErrorAction SilentlyContinue
        if ($cmd) { $PythonPath = $cmd.Source }
    }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
    Write-Fail 'python 실행 파일을 찾지 못했습니다. -PythonPath 로 지정하세요.'
    exit 1
}
Write-Ok "python: $PythonPath"

# ---------------------------------------------------------------- 프로파일 패치 정합성
# install.ps1 은 python 실행 파일의 절대경로를 cordis.patch.yml 에 기록한다. DSH가
# 번들 런타임을 재생성하면 그 경로가 어긋나 MCP 서버가 조용히 뜨지 않는다(가장 흔한
# 실패 모드). 관리 블록을 읽어 드리프트를 감지하고 재설치를 안내한다.
$BeginMarker = '# >>> dsh-web-search-mcp managed block (do not edit) >>>'
$EndMarker = '# <<< dsh-web-search-mcp managed block <<<'

$ProfilesRoot = Join-Path $DshHome 'profiles'
$ProfileDir = $null
if ($Profile) {
    $candidate = Join-Path $ProfilesRoot $Profile
    if (Test-Path -LiteralPath $candidate) { $ProfileDir = $candidate }
    else { Write-Warn2 "프로파일 디렉터리가 없습니다: $candidate" }
} elseif (Test-Path -LiteralPath $ProfilesRoot) {
    $candidates = @(Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cordis.patch.yml') })
    if ($candidates.Count -eq 1) { $ProfileDir = $candidates[0].FullName }
    elseif ($candidates.Count -gt 1) { Write-Warn2 '프로파일이 여러 개입니다. -Profile 로 지정하세요(패치 점검 생략).' }
}

if ($ProfileDir) {
    $PatchPath = Join-Path $ProfileDir 'cordis.patch.yml'
    $patchLines = @(([System.IO.File]::ReadAllText($PatchPath)) -split "`r?`n")
    $inside = $false
    $PatchCommand = $null
    $PatchScript = $null
    $PatchDshHome = $null
    foreach ($line in $patchLines) {
        $t = "$line".Trim()
        if ($t -eq $BeginMarker) { $inside = $true; continue }
        if ($t -eq $EndMarker) { break }
        if (-not $inside) { continue }
        if (-not $PatchCommand -and $line -match "^\s*command:\s*'([^']*)'\s*$") { $PatchCommand = $Matches[1] }
        if (-not $PatchScript -and $line -match "^\s*-\s*'([^']*dsh-web-search\.py)'\s*$") { $PatchScript = $Matches[1] }
        if (-not $PatchDshHome -and $line -match "^\s*DSH_HOME:\s*'([^']*)'\s*$") { $PatchDshHome = $Matches[1] }
    }

    if (-not $PatchCommand) {
        Write-Fail '프로파일 패치의 관리 블록에서 command 를 찾지 못했습니다.'
        Write-Info 'install.ps1 을 실행하세요.'
        $failures++
    } else {
        $commandOk = Test-Path -LiteralPath $PatchCommand
        if ($commandOk) {
            Write-Ok "패치 command 경로 확인: $PatchCommand"
            if (-not [string]::Equals($PatchCommand, $PythonPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Info "탐지된 python 과 다릅니다(둘 다 유효): $PythonPath"
            }
        } else {
            Write-Fail "패치의 command 경로가 존재하지 않습니다: $PatchCommand"
            Write-Info 'DSH 번들 런타임이 재생성된 것으로 보입니다. install.ps1 을 다시 실행해 경로를 갱신하세요.'
            $failures++
        }

        if ($PatchScript) {
            if (Test-Path -LiteralPath $PatchScript) {
                if (-not [string]::Equals($PatchScript, $ScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-Warn2 "패치의 args 경로가 설치 경로와 다릅니다: $PatchScript"
                } else {
                    Write-Ok "패치 args 경로 확인: $PatchScript"
                }
            } else {
                Write-Fail "패치의 args 경로가 존재하지 않습니다: $PatchScript"
                Write-Info 'install.ps1 을 다시 실행하세요.'
                $failures++
            }
        }

        # DSH는 자식 프로세스 환경에서 DSH_* 를 제거하므로, 서버가 올바른 홈을 쓰려면
        # MCP 행의 env 에 DSH_HOME 이 들어 있어야 한다(특히 기본이 아닌 DSH 홈).
        if ($PatchDshHome) {
            $patchHomeFull = try { [System.IO.Path]::GetFullPath($PatchDshHome) } catch { $PatchDshHome }
            if ([string]::Equals($patchHomeFull, $DshHome, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Ok "패치 env DSH_HOME 확인: $PatchDshHome"
            } else {
                Write-Fail "패치의 env DSH_HOME 이 이 DSH 홈과 다릅니다: $PatchDshHome (기대: $DshHome)"
                Write-Info 'install.ps1 을 다시 실행하세요.'
                $failures++
            }
        } else {
            Write-Warn2 '패치에 env DSH_HOME 이 없습니다.'
            Write-Info 'DSH가 자식 프로세스 환경에서 DSH_* 를 제거하므로, 기본이 아닌 DSH 홈에서는 서버가 자격증명을 찾지 못합니다.'
        }
    }
}

# 설치본이 이 프로젝트의 최신 소스와 같은지 (git pull 후 재설치 누락 감지)
if ((Test-Path -LiteralPath $SourceScript) -and (Test-Path -LiteralPath $ScriptPath)) {
    $installedHash = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $SourceScript -Algorithm SHA256).Hash
    if ($installedHash -eq $sourceHash) {
        Write-Ok '설치된 서버 스크립트 = 프로젝트 소스 (SHA256 일치)'
    } else {
        Write-Warn2 '설치된 서버 스크립트가 server\dsh-web-search.py 와 다릅니다.'
        Write-Info 'install.ps1 을 다시 실행하면 최신 스크립트로 갱신됩니다.'
    }
}

# ---------------------------------------------------------------- 설정 상태
$CredPath = Join-Path $DshHome '.credentials.yaml'
if ((Test-Path -LiteralPath $CredPath) -and
    ([regex]::IsMatch([System.IO.File]::ReadAllText($CredPath), '(?m)^\s*OPENROUTER_API_KEY\s*:\s*\S+'))) {
    Write-Ok 'OpenRouter API 키 확인 (.credentials.yaml)'
} else {
    Write-Warn2 'OpenRouter API 키를 찾지 못했습니다. 검색은 실패합니다.'
}

$UserCfg = Join-Path $DshHome 'web-search.json'
if (Test-Path -LiteralPath $UserCfg) {
    $model = 'deepseek/deepseek-v4.1-flash'
    try {
        $json = Get-Content -LiteralPath $UserCfg -Raw | ConvertFrom-Json
        if ($json.model) { $model = $json.model }
    } catch { Write-Warn2 "web-search.json 파싱 실패: $UserCfg" }
    Write-Info "검색 모델(web-search.json): $model"
} else {
    Write-Info '검색 모델(기본값): deepseek/deepseek-v4.1-flash'
}

# ---------------------------------------------------------------- stdio 프로브
$requests = New-Object System.Collections.Generic.List[string]
$requests.Add('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"dsh-verify","version":"1.0"}}}')
$requests.Add('{"jsonrpc":"2.0","method":"notifications/initialized"}')
$requests.Add('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
if ($Search) {
    $escaped = $Query.Replace('\', '\\').Replace('"', '\"')
    $requests.Add('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"' + $escaped + '","max_results":3}}}')
}

$errFile = [System.IO.Path]::GetTempFileName()
$raw = ($requests -join "`n") + "`n"
# 네이티브 명령의 stderr 출력은 ErrorActionPreference=Stop 에서 종료 오류로 승격된다
# (Windows PowerShell 5.1). 프로브 구간에서는 Continue 로 낮추고 서버 로그는 파일로 받는다.
# 서버는 DSH_HOME 을 보고 자격증명/설정을 찾는다. DSH 본체는 자식 환경에서 DSH_* 를
# 제거하지만, 이 프로브는 우리가 직접 띄우므로 패치가 넘기는 것과 같은 값을 넘겨
# 실제 실행 환경과 동일하게 만든다.
$prevDshHome = $env:DSH_HOME
$env:DSH_HOME = $DshHome
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $out = $raw | & $PythonPath $ScriptPath 2>$errFile
} catch {
    Write-Fail "프로브 실행 실패: $_"
    exit 1
} finally {
    $ErrorActionPreference = $prevEap
    if ($null -eq $prevDshHome) { Remove-Item Env:\DSH_HOME -ErrorAction SilentlyContinue }
    else { $env:DSH_HOME = $prevDshHome }
}

$responses = @{}
foreach ($line in $out) {
    if (-not "$line".Trim()) { continue }
    try { $obj = $line | ConvertFrom-Json } catch { continue }
    if ($null -ne $obj.id) { $responses[[string]$obj.id] = $obj }
}

# 1) initialize
if ($responses.ContainsKey('1')) {
    $init = $responses['1'].result
    Write-Ok "initialize: protocolVersion=$($init.protocolVersion), serverInfo=$($init.serverInfo.name) v$($init.serverInfo.version)"
} else {
    Write-Fail 'initialize 응답이 없습니다.'
    $failures++
}

# 2) tools/list
if ($responses.ContainsKey('2')) {
    $names = @($responses['2'].result.tools | ForEach-Object { $_.name })
    if ($names -contains 'web_search' -and $names -contains 'web_fetch') {
        Write-Ok "tools/list: $($names -join ', ')"
    } else {
        Write-Fail "tools/list 에 필요한 도구가 없습니다: $($names -join ', ')"
        $failures++
    }
} else {
    Write-Fail 'tools/list 응답이 없습니다.'
    $failures++
}

# 3) DSH 쪽 연결 여부
# 경로까지 일치하는 프로세스를 우선 찾는다(다른 DSH 홈에 설치된 사본과 구분).
$child = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'python*' -and $_.CommandLine -and $_.CommandLine.Contains($ScriptPath) })
if ($child.Count -eq 0) {
    $child = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'python*' -and $_.CommandLine -like '*dsh-web-search.py*' })
    if ($child.Count -gt 0) {
        Write-Info '다른 경로의 dsh-web-search.py 프로세스가 실행 중입니다(이 설치가 아닐 수 있음).'
    }
}
if ($child.Count -gt 0) {
    $ids = ($child | ForEach-Object { $_.ProcessId }) -join ', '
    Write-Ok "DSH가 MCP 서버를 실행 중입니다 (PID $ids)"
} else {
    Write-Warn2 'DSH 쪽 MCP 자식 프로세스가 없습니다. DSH를 재시작했는지 확인하세요.'
}

# 4) 실제 검색
if ($Search) {
    if ($responses.ContainsKey('3')) {
        $res = $responses['3'].result
        $text = ($res.content | Select-Object -First 1).text
        if ($res.isError) {
            Write-Fail "web_search 실패: $text"
            $failures++
        } else {
            $citations = @([regex]::Matches($text, '(?m)^\[\d+\]')).Count
            Write-Ok ("web_search 성공: 응답 {0}자, 출처 {1}건" -f $text.Length, $citations)
            $head = ($text -split "`n" | Select-Object -First 4) -join ' / '
            Write-Info $head
        }
    } else {
        Write-Fail 'web_search 응답이 없습니다.'
        $failures++
    }
}

$stderr = Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue
if ($stderr) {
    # Windows PowerShell 5.1 은 네이티브 stderr 를 ErrorRecord 로 감싸므로
    # 서버가 실제로 남긴 로그 줄만 골라 보여준다.
    $logLines = @($stderr | Where-Object { "$_" -match '\[dsh-web-search\]' })
    if ($logLines.Count -gt 0) {
        Write-Host '  --- 서버 stderr ---' -ForegroundColor DarkGray
        $logLines | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}
Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host '결과: 정상' -ForegroundColor Green
    exit 0
} else {
    Write-Host "결과: 실패 $failures 건" -ForegroundColor Red
    exit 1
}