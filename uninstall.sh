#!/usr/bin/env bash
#
# dsh-web-search-mcp 제거 스크립트 (macOS / POSIX)
#
#   1. 프로파일 cordis.patch.yml 에서 관리 블록 제거 (원본은 백업)
#   2. <DSH_HOME>/AGENTS.md 에서 관리 섹션 제거 (남는 내용이 없으면 파일 삭제)
#   3. <DSH_HOME>/mcp/dsh-web-search.py 삭제 (+ 바이트코드 캐시, 빈 디렉터리)
#
# ~/.dsh/web-search.json 과 .credentials.yaml 은 사용자 자산이므로 건드리지 않는다.
#
# 사용법:
#   bash uninstall.sh
#   bash uninstall.sh --dry-run
#
# bash 3.2(macOS 기본 /bin/bash)에서 동작하도록 작성했다.

set -euo pipefail

_self=$0
case "$_self" in
    */*) _selfdir=${_self%/*} ;;
    *)   _selfdir=. ;;
esac
SCRIPT_DIR=$(cd -- "$_selfdir" && pwd -P)
COMMON="$SCRIPT_DIR/tools/posix-common.sh"
HELPER="$SCRIPT_DIR/tools/cordis_patch.py"

DSH_HOME_ARG=""
PROFILE_ARG=""
PYTHON_ARG=""
DRY_RUN=0

usage() {
    cat <<'USAGE'
dsh-web-search-mcp 제거 스크립트

사용법:
  bash uninstall.sh
  bash uninstall.sh --dry-run

옵션:
  --dsh-home <경로>   DSH 홈 (기본: $DSH_HOME, 그다음 ~/.dsh)
  --profile <이름>    프로파일 (기본: 자동 탐지)
  --python <경로>     패치 편집에 쓸 python3 (기본: DSH 번들 런타임 → PATH)
  --dry-run           실제로 삭제하지 않고 계획만 출력
  -h, --help          이 도움말

참고: ~/.dsh/web-search.json 과 .credentials.yaml 은 그대로 유지된다.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dsh-home)   [ $# -ge 2 ] || { printf 'X --dsh-home 에 값이 필요합니다.\n' >&2; exit 2; }; DSH_HOME_ARG=$2; shift 2 ;;
        --dsh-home=*) DSH_HOME_ARG=${1#*=}; shift ;;
        --profile)    [ $# -ge 2 ] || { printf 'X --profile 에 값이 필요합니다.\n' >&2; exit 2; }; PROFILE_ARG=$2; shift 2 ;;
        --profile=*)  PROFILE_ARG=${1#*=}; shift ;;
        --python)     [ $# -ge 2 ] || { printf 'X --python 에 값이 필요합니다.\n' >&2; exit 2; }; PYTHON_ARG=$2; shift 2 ;;
        --python=*)   PYTHON_ARG=${1#*=}; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf 'X 알 수 없는 옵션: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

[ -f "$COMMON" ] || { printf '필수 파일이 없습니다: %s\n' "$COMMON" >&2; exit 1; }
# shellcheck source=tools/posix-common.sh
. "$COMMON"

resolve_home "$DSH_HOME_ARG"
step "DSH 홈: $DSH_HOME_DIR"

resolve_python "$DSH_HOME_DIR" "$PYTHON_ARG"

# ---------------------------------------------------------------- 1. 패치 파일

step '프로파일 패치 정리'
if resolve_profile "$DSH_HOME_DIR" "$PROFILE_ARG" 1; then
    PATCH_PATH="$PROFILE_DIR/cordis.patch.yml"
    if [ -f "$PATCH_PATH" ]; then
        if LC_ALL=C grep -qF "$PATCH_BEGIN" "$PATCH_PATH"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                info "[dry-run] 관리 블록을 제거합니다: $PATCH_PATH"
            else
                _stamp=$(date +%Y%m%d-%H%M%S)
                cp -f "$PATCH_PATH" "$PATCH_PATH.bak-$_stamp"
                ok "백업 생성: ${PATCH_PATH##*/}.bak-$_stamp"
                _summary=$("$PYTHON" "$HELPER" patch-remove "$PATCH_PATH")
                ok "관리 블록 제거 ($_summary)"
            fi
        else
            info '관리 블록이 없습니다(이미 제거됨).'
        fi
    else
        info '프로파일 패치 파일을 찾지 못했습니다(건너뜀).'
    fi
else
    info '프로파일 패치 파일을 찾지 못했습니다(건너뜀).'
fi

# ---------------------------------------------------------------- 2. AGENTS.md

AGENTS_PATH="$DSH_HOME_DIR/AGENTS.md"
step "AGENTS.md 정리: $AGENTS_PATH"
if [ -f "$AGENTS_PATH" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        info '[dry-run] 관리 섹션을 제거합니다.'
    else
        _summary=$("$PYTHON" "$HELPER" agents-remove "$AGENTS_PATH")
        case "$_summary" in
            cleaned) _agents_action='관리 섹션 제거' ;;
            removed*) _agents_action='삭제(남은 내용 없음)' ;;
            absent) _agents_action='없음(건너뜀)' ;;
            *) _agents_action=$_summary ;;
        esac
        ok "AGENTS.md $_agents_action"
    fi
else
    info 'AGENTS.md 가 없습니다(건너뜀).'
fi

# ---------------------------------------------------------------- 3. 서버 스크립트

MCP_DIR="$DSH_HOME_DIR/mcp"
TARGET_SCRIPT="$MCP_DIR/dsh-web-search.py"
step "서버 스크립트 삭제: $TARGET_SCRIPT"
if [ -f "$TARGET_SCRIPT" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        info '[dry-run] 삭제 예정'
    else
        rm -f "$TARGET_SCRIPT"
        ok '삭제 완료'
        # 서버 스크립트를 실행·임포트한 과정에서 생긴 바이트코드 캐시가 남으면
        # mcp 디렉터리가 비지 않아 아래 정리 단계가 동작하지 않는다.
        # 남의 파일은 건드리지 않도록 우리 모듈의 캐시만 골라 지운다.
        CACHE_DIR="$MCP_DIR/__pycache__"
        if [ -d "$CACHE_DIR" ]; then
            for _pyc in "$CACHE_DIR"/dsh-web-search*.pyc; do
                [ -e "$_pyc" ] || continue
                rm -f "$_pyc"
            done
            if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null || true)" ]; then
                rmdir "$CACHE_DIR"
                ok '바이트코드 캐시(__pycache__) 삭제'
            else
                info "mcp 디렉터리에 다른 파일이 남아 있습니다: $CACHE_DIR"
            fi
        fi
        if [ -d "$MCP_DIR" ] && [ -z "$(ls -A "$MCP_DIR" 2>/dev/null || true)" ]; then
            rmdir "$MCP_DIR"
            ok '빈 mcp 디렉터리 삭제'
        fi
    fi
else
    info '설치된 서버 스크립트가 없습니다(건너뜀).'
fi

printf '\n%s제거 완료. DSH를 재시작하면 반영됩니다.%s\n' "$C_YELLOW" "$C_OFF"
printf '%s참고: ~/.dsh/web-search.json 과 .credentials.yaml 은 그대로 유지됩니다.%s\n' "$C_GRAY" "$C_OFF"
