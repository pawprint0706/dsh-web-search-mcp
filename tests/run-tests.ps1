#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-web-search-mcp 테스트 실행 스크립트.

.DESCRIPTION
  저장소 루트에서 `python -m unittest discover -s tests -v` 를 실행하고 종료 코드를
  그대로 전달한다.

  테스트 실행 전에 정적 검사를 먼저 수행한다(기본 동작).
    1) 저장소의 모든 *.ps1 이 UTF-8(BOM 포함)인지 확인
       - BOM 이 없으면 Windows PowerShell 5.1 이 한글을 CP949 로 오해석해 구문
         오류가 발생한다(README 3절 요구사항). 하나라도 아니면 exit 1.
    2) PowerShell 파서([System.Management.Automation.Language.Parser])로 구문
       오류가 0건인지 확인. 오류가 있으면 exit 1.

  python 실행 파일은 다음 순서로 찾는다.
    ① $env:DSH_HOME (없으면 ~/.dsh) 아래
       dsh-runtimes\*\dependencies\python\python.exe 중 최신
    ② PATH 의 python

.PARAMETER PythonPath
  사용할 python.exe 경로를 직접 지정한다(자동 탐색 생략).

.PARAMETER CheckOnly
  정적 검사(BOM/구문)만 수행하고 테스트는 실행하지 않는다(CI 용).

.PARAMETER SkipStaticChecks
  정적 검사를 건너뛰고 테스트만 실행한다.

.PARAMETER TestPath
  unittest discover 시작 디렉터리. 기본값: tests (저장소 루트 기준).

.EXAMPLE
  .\tests\run-tests.ps1

.EXAMPLE
  .\tests\run-tests.ps1 -PythonPath C:\Python314\python.exe

.EXAMPLE
  .\tests\run-tests.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$PythonPath,
    [switch]$CheckOnly,
    [switch]$SkipStaticChecks,
    [string]$TestPath = 'tests'
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 콘솔에서 한글이 깨지지 않도록 출력 인코딩을 UTF-8 로 맞춘다.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

function Write-Ok([string]$Text) { Write-Host "  [PASS] $Text" -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  - $Text" -ForegroundColor Gray }

function Get-PsScriptTargets {
    $targets = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in @(Get-ChildItem -LiteralPath $RepoRoot -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {
        $targets.Add($file)
    }
    $testsDir = Join-Path $RepoRoot 'tests'
    if (Test-Path -LiteralPath $testsDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $testsDir -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue)) {
            $targets.Add($file)
        }
    }
    return $targets
}

function Test-Utf8Bom([System.IO.FileInfo]$File) {
    $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    if ($bytes.Length -lt 3) { return $false }
    return ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# ---------------------------------------------------------------- 정적 검사
if (-not $SkipStaticChecks) {
    Write-Host '=== 정적 검사 (UTF-8 BOM / 구문) ===' -ForegroundColor Cyan
    $staticFailures = 0
    $targets = @(Get-PsScriptTargets)

    if ($targets.Count -eq 0) {
        Write-Fail '검사할 .ps1 파일을 찾지 못했습니다.'
        $staticFailures++
    }

    foreach ($file in $targets) {
        if (Test-Utf8Bom -File $file) {
            Write-Ok ("UTF-8 BOM: {0}" -f $file.Name)
        } else {
            Write-Fail ("UTF-8 BOM 없음: {0} (PowerShell 5.1 에서 한글이 CP949 로 오해석됩니다)" -f $file.FullName)
            $staticFailures++
        }
    }

    foreach ($file in $targets) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Fail ("구문 오류 {0}건: {1}" -f $parseErrors.Count, $file.Name)
            foreach ($err in $parseErrors) {
                Write-Info ("줄 {0}: {1}" -f $err.Extent.StartLineNumber, $err.Message)
            }
            $staticFailures++
        } else {
            Write-Ok ("구문 정상: {0}" -f $file.Name)
        }
    }

    if ($staticFailures -gt 0) {
        Write-Host ''
        Write-Host ("정적 검사 실패: {0}건" -f $staticFailures) -ForegroundColor Red
        exit 1
    }
}

if ($CheckOnly) {
    Write-Host ''
    Write-Host '정적 검사 결과: 정상' -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- python 탐색
Write-Host '=== python 실행 파일 탐색 ===' -ForegroundColor Cyan
if (-not $PythonPath) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
    $RuntimesRoot = Join-Path $DshHome 'dsh-runtimes'
    if (Test-Path -LiteralPath $RuntimesRoot) {
        $candidates = @(
            Get-ChildItem -LiteralPath $RuntimesRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'dependencies\python\python.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending
        )
        if ($candidates.Count -gt 0) { $PythonPath = $candidates[0] }
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
Write-Ok ("python: {0}" -f $PythonPath)

$StartDir = if ([System.IO.Path]::IsPathRooted($TestPath)) { $TestPath } else { Join-Path $RepoRoot $TestPath }
if (-not (Test-Path -LiteralPath $StartDir)) {
    Write-Fail ("테스트 디렉터리가 없습니다: {0}" -f $StartDir)
    exit 1
}

# ---------------------------------------------------------------- 테스트 실행
Write-Host '=== 테스트 실행 (unittest discover) ===' -ForegroundColor Cyan
$exitCode = 1
$prevEap = $ErrorActionPreference
$prevPyIoEncoding = $env:PYTHONIOENCODING
# unittest 는 진행 상황/실패 요약을 stderr 로 쓴다. Windows PowerShell 5.1 에서는
# ErrorActionPreference=Stop 일 때 네이티브 stderr 가 종료 오류로 승격되므로
# 실행 구간만 Continue 로 낮춘다.
# 또한 자식 python 의 stdio 인코딩을 UTF-8 로 고정한다. 그러지 않으면 한글 테스트
# 이름이 CP949 로 나가 위에서 맞춘 [Console]::OutputEncoding(UTF-8) 과 어긋나 깨진다.
$ErrorActionPreference = 'Continue'
$env:PYTHONIOENCODING = 'utf-8'
Push-Location -LiteralPath $RepoRoot
try {
    & $PythonPath -m unittest discover -s $TestPath -v
    if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
} finally {
    if ($null -eq $prevPyIoEncoding) {
        Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONIOENCODING = $prevPyIoEncoding
    }
    $ErrorActionPreference = $prevEap
    Pop-Location
}

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host '테스트 결과: 성공' -ForegroundColor Green
} else {
    Write-Host ("테스트 결과: 실패 (exit {0})" -f $exitCode) -ForegroundColor Red
}
exit $exitCode
