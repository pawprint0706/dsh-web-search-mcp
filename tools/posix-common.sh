#!/usr/bin/env bash
#
# dsh-web-search-mcp POSIX 공용 함수 (install.sh / verify.sh / uninstall.sh 가 source 한다)
#
# bash 3.2(macOS 기본 /bin/bash)에서 동작하도록 작성했다: 연관 배열, mapfile,
# ${var,,}, <<< 같은 bash 4+/비POSIX 기능을 쓰지 않는다.
#
# 이 파일은 함수만 정의하고 아무것도 실행하지 않는다(색상 초기화 제외).
# 호출 스크립트가 `set -euo pipefail` 을 먼저 설정한다고 가정한다.

# ---------------------------------------------------------------- 마커

# tools/cordis_patch.py 의 상수와 반드시 같아야 한다(그쪽이 실제 편집을 수행한다).
PATCH_BEGIN='# >>> dsh-web-search-mcp managed block (do not edit) >>>'
PATCH_END='# <<< dsh-web-search-mcp managed block <<<'
AGENTS_BEGIN='<!-- dsh-web-search-mcp:begin -->'
AGENTS_END='<!-- dsh-web-search-mcp:end -->'

# ---------------------------------------------------------------- 출력

if [ -t 1 ]; then
    C_CYAN=$(printf '\033[36m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_RED=$(printf '\033[31m')
    C_GRAY=$(printf '\033[90m')
    C_OFF=$(printf '\033[0m')
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; C_OFF=""
fi

step() { printf '%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf '    %s[OK]%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
pass() { printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info() { printf '    %s- %s%s\n' "$C_GRAY" "$1" "$C_OFF"; }
warn() { printf '    %s[!]%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
bad()  { printf '    %s[X]%s %s\n' "$C_RED" "$C_OFF" "$1"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; }

die() {
    bad "$1"
    exit 1
}

# ---------------------------------------------------------------- 경로/python

# 외부 dirname/basename(-- 미지원 가능) 대신 순수 bash 로 절대경로를 만든다.
absolute_path() {
    _path=$1
    _dir=${_path%/*}
    if [ "$_dir" = "$_path" ]; then
        _dir="."
    fi
    printf '%s/%s\n' "$(cd -- "$_dir" && pwd -P)" "${_path##*/}"
}

python_version_ok() {
    _exe=$1
    _out=$("$_exe" --version 2>&1 | head -n 1) || return 1
    case "$_out" in
        Python\ 3.*) ;;
        *) return 1 ;;
    esac
    _maj=$(printf '%s' "$_out" | sed -n 's/^Python \([0-9][0-9]*\)\..*/\1/p')
    _min=$(printf '%s' "$_out" | sed -n 's/^Python [0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')
    [ -n "$_maj" ] && [ -n "$_min" ] || return 1
    if [ "$_maj" -gt 3 ]; then return 0; fi
    if [ "$_maj" -eq 3 ] && [ "$_min" -ge 8 ]; then return 0; fi
    return 1
}

python_version_text() {
    "$1" --version 2>&1 | head -n 1 || true
}

# DSH 번들 런타임의 python 을 찾는다. macOS/Linux 는 dependencies/python/bin/python3,
# Windows 는 dependencies/python/python.exe 다(DSH 런타임 규칙).
#   $1 = DSH 홈
find_runtime_python() {
    _root="$1/dsh-runtimes"
    [ -d "$_root" ] || return 1
    for _rel in dependencies/python/bin/python3 dependencies/python/bin/python dependencies/python/python.exe; do
        _cand="$_root/dsh-primary-runtime/$_rel"
        if [ -f "$_cand" ] && [ -x "$_cand" ] && python_version_ok "$_cand"; then
            printf '%s\n' "$_cand"
            return 0
        fi
    done
    for _dir in "$_root"/*; do
        [ -d "$_dir" ] || continue
        for _rel in dependencies/python/bin/python3 dependencies/python/bin/python dependencies/python/python.exe; do
            _cand="$_dir/$_rel"
            if [ -f "$_cand" ] && [ -x "$_cand" ] && python_version_ok "$_cand"; then
                printf '%s\n' "$_cand"
                return 0
            fi
        done
    done
    return 1
}

# PYTHON 전역을 설정한다.
#   $1 = DSH 홈, $2 = 명시적 python 경로(없으면 빈 문자열)
resolve_python() {
    _home=$1
    _explicit=${2:-}
    PYTHON=""
    if [ -n "$_explicit" ]; then
        [ -x "$_explicit" ] || die "--python 이 실행 가능한 파일이 아닙니다: $_explicit"
        python_version_ok "$_explicit" || die "--python 이 python 3.8+ 가 아닙니다: $_explicit ($(python_version_text "$_explicit"))"
        PYTHON=$(absolute_path "$_explicit")
        return 0
    fi
    PYTHON=$(find_runtime_python "$_home" || true)
    if [ -z "$PYTHON" ]; then
        for _name in python3 python; do
            _cand=$(command -v "$_name" 2>/dev/null || true)
            if [ -n "$_cand" ] && python_version_ok "$_cand"; then
                PYTHON=$(absolute_path "$_cand")
                break
            fi
        done
    fi
    [ -n "$PYTHON" ] || die "python 3.8+ 를 찾지 못했습니다. DSH 번들 런타임이 없다면 python 을 설치하거나 --python 으로 지정하세요."
}

# DSH_HOME_DIR 전역을 설정한다.
#   $1 = 명시적 홈(없으면 빈 문자열)
resolve_home() {
    _arg=${1:-}
    if [ -z "$_arg" ]; then
        if [ -n "${DSH_HOME:-}" ]; then
            _arg=$DSH_HOME
        else
            _arg=$HOME/.dsh
        fi
    fi
    [ -d "$_arg" ] || die "DSH 홈을 찾을 수 없습니다: $_arg (DSH를 최소 한 번 실행하거나 --dsh-home 으로 지정하세요)"
    DSH_HOME_DIR=$(cd -- "$_arg" && pwd -P)
}

# PROFILE_DIR / PROFILE_NAME 전역을 설정한다.
#   $1 = DSH 홈, $2 = 명시적 프로파일 이름(없으면 빈 문자열), $3 = 1 이면 실패 시 die 대신 경고+return 1
resolve_profile() {
    _home=$1
    _arg=${2:-}
    _soft=${3:-0}
    _root="$_home/profiles"
    if [ -n "$_arg" ]; then
        PROFILE_DIR="$_root/$_arg"
        if [ ! -d "$PROFILE_DIR" ]; then
            if [ "$_soft" = "1" ]; then warn "프로파일 디렉터리가 없습니다: $PROFILE_DIR"; return 1; fi
            die "프로파일 디렉터리가 없습니다: $PROFILE_DIR"
        fi
    else
        _count=0
        _found=""
        if [ -d "$_root" ]; then
            for _d in "$_root"/*; do
                [ -d "$_d" ] || continue
                if [ -f "$_d/cordis.patch.yml" ]; then
                    _count=$((_count + 1))
                    _found=$_d
                fi
            done
        fi
        if [ "$_count" -eq 1 ]; then
            PROFILE_DIR=$_found
        elif [ "$_count" -eq 0 ]; then
            if [ "$_soft" = "1" ]; then warn "cordis.patch.yml 을 가진 프로파일을 찾지 못했습니다: $_root"; return 1; fi
            die "cordis.patch.yml 을 가진 프로파일을 찾지 못했습니다: $_root (DSH를 최소 한 번 실행하세요)"
        else
            if [ "$_soft" = "1" ]; then warn "프로파일이 여러 개입니다. --profile 로 지정하세요."; return 1; fi
            bad "프로파일이 여러 개입니다. --profile 로 지정하세요:"
            for _d in "$_root"/*; do
                [ -f "$_d/cordis.patch.yml" ] && info "${_d##*/}"
            done
            exit 1
        fi
    fi
    PROFILE_NAME=${PROFILE_DIR##*/}
    return 0
}

# 파일 SHA256(외부 도구 대신 python 사용 — macOS shasum/linux sha256sum 차이 회피)
file_sha256() {
    "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}
