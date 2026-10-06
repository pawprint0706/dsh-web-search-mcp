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
$ScriptPath = Join-Path (Join-Path $DshHome 'mcp') 'dsh-web-search.py'

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
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $out = $raw | & $PythonPath $ScriptPath 2>$errFile
} catch {
    Write-Fail "프로브 실행 실패: $_"
    exit 1
} finally {
    $ErrorActionPreference = $prevEap
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
$child = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'python*' -and $_.CommandLine -like '*dsh-web-search.py*' }
if ($child) {
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