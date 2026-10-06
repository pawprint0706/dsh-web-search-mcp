#!/usr/bin/env bash
#
# dsh-web-search-mcp 설치 스크립트 (macOS, 멱등)
#
# DSH(DeepSeek Harness)에 OpenRouter 기반 웹 검색 MCP 서버를 설치한다.
# 자세한 사용법과 옵션은 `bash install.sh --help` 를 참고한다.
#
# 참고: macOS 전용이다. 다른 플랫폼에서는 실패한다(테스트 목적이면
#       DSH_INSTALL_FORCE_PLATFORM=1 로 우회할 수 있다).
#
# bash 3.2(macOS 기본 /bin/bash)에서 동작하도록 작성했다: 연관 배열, mapfile,
# ${var,,} 같은 bash 4+ 기능을 쓰지 않는다.

set -euo pipefail

_self=$0
case "$_self" in
    */*) _selfdir=${_self%/*} ;;
    *)   _selfdir=. ;;
esac
SCRIPT_DIR=$(cd -- "$_selfdir" && pwd -P)
COMMON="$SCRIPT_DIR/tools/posix-common.sh"
HELPER="$SCRIPT_DIR/tools/cordis_patch.py"
SOURCE_SCRIPT="$SCRIPT_DIR/server/dsh-web-search.py"
SOURCE_AGENTS="$SCRIPT_DIR/templates/AGENTS.md"

DSH_HOME_ARG=""
PROFILE_ARG=""
PYTHON_ARG=""
DRY_RUN=0
SKIP_VERIFY=0
NO_AGENTS=0

# ---------------------------------------------------------------- 출력/공용 함수

[ -f "$COMMON" ] || { printf '필수 파일이 없습니다: %s\n' "$COMMON" >&2; exit 1; }
# shellcheck source=tools/posix-common.sh
. "$COMMON"

usage() {
    cat <<'USAGE'
dsh-web-search-mcp 설치 스크립트 (macOS, 멱등)

사용법:
  bash install.sh
  bash install.sh --dsh-home "$HOME/.dsh" --profile desktop
  bash install.sh --dry-run

옵션:
  --dsh-home <경로>   DSH 홈 (기본: $DSH_HOME, 그다음 ~/.dsh)
  --profile <이름>    프로파일 (기본: cordis.patch.yml 을 가진 프로파일 자동 탐지)
  --python <경로>     MCP 서버를 실행할 python3 (기본: DSH 번들 런타임 → PATH)
  --dry-run           파일을 쓰지 않고 계획만 출력
  --skip-verify       설치 후 자체 점검(verify.sh) 생략
  --no-agents         AGENTS.md 관리 섹션 설치 생략
  -h, --help          이 도움말

설치가 하는 일:
  1. server/dsh-web-search.py 를 <DSH_HOME>/mcp/ 로 복사
  2. <DSH_HOME>/AGENTS.md 에 "MCP 검색 도구를 사용하라"는 관리 섹션 추가
  3. <DSH_HOME>/profiles/<profile>/cordis.patch.yml 에 관리 블록 추가
       - 내장 web-search-deepseek 비활성화 (OpenRouter에서 동작하지 않음)
       - @deepseek-ai/dsh-mcp-client 행 삽입 (MCP stdio 서버 등록)

  재실행해도 안전하다(멱등): 관리 블록은 통째로 교체되고, 손으로 넣은 동일 id 항목은
  중복 등록을 막기 위해 제거된다. 수정 전 원본은 타임스탬프 백업으로 남는다.

참고: macOS 전용이다. 다른 플랫폼에서는 실패한다(테스트 목적이면
      DSH_INSTALL_FORCE_PLATFORM=1 로 우회할 수 있다).
USAGE
}

# ---------------------------------------------------------------- 옵션

while [ $# -gt 0 ]; do
    case "$1" in
        --dsh-home)   [ $# -ge 2 ] || { bad "--dsh-home 에 값이 필요합니다."; exit 2; }; DSH_HOME_ARG=$2; shift 2 ;;
        --dsh-home=*) DSH_HOME_ARG=${1#*=}; shift ;;
        --profile)    [ $# -ge 2 ] || { bad "--profile 에 값이 필요합니다."; exit 2; }; PROFILE_ARG=$2; shift 2 ;;
        --profile=*)  PROFILE_ARG=${1#*=}; shift ;;
        --python)     [ $# -ge 2 ] || { bad "--python 에 값이 필요합니다."; exit 2; }; PYTHON_ARG=$2; shift 2 ;;
        --python=*)   PYTHON_ARG=${1#*=}; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        --no-agents)  NO_AGENTS=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            bad "알 수 없는 옵션: $1"; usage; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 0. 플랫폼

UNAME_S=$(uname -s)
if [ "$UNAME_S" != "Darwin" ] && [ "${DSH_INSTALL_FORCE_PLATFORM:-0}" != "1" ]; then
    bad "이 스크립트는 macOS(Darwin)용입니다. 현재 플랫폼: $UNAME_S"
    info "Windows 에서는 install.ps1 을 사용하세요."
    info "테스트 목적으로 강제 실행하려면 DSH_INSTALL_FORCE_PLATFORM=1 을 설정하세요."
    exit 1
fi
if [ "$UNAME_S" != "Darwin" ]; then
    warn "Darwin 이 아닌 플랫폼에서 강제 실행 중입니다(DSH_INSTALL_FORCE_PLATFORM=1): $UNAME_S"
fi

[ -f "$HELPER" ] || die "필수 파일이 없습니다: $HELPER"
[ -f "$SOURCE_SCRIPT" ] || die "필수 파일이 없습니다: $SOURCE_SCRIPT"

# ---------------------------------------------------------------- 1. DSH 홈

step 'DSH 홈 확인'
resolve_home "$DSH_HOME_ARG"
ok "DSH 홈: $DSH_HOME_DIR"

# ---------------------------------------------------------------- 2. 프로파일

step '프로파일 확인'
resolve_profile "$DSH_HOME_DIR" "$PROFILE_ARG"
PATCH_PATH="$PROFILE_DIR/cordis.patch.yml"
ok "프로파일: $PROFILE_NAME"
info "패치 파일: $PATCH_PATH"

# ---------------------------------------------------------------- 3. python

step 'python 실행 파일 확인'

resolve_python "$DSH_HOME_DIR" "$PYTHON_ARG"
ok "python: $PYTHON ($(python_version_text "$PYTHON"))"

# ---------------------------------------------------------------- 4. 사전 점검

step '사전 점검'
ok '서버 스크립트 확인'

CRED_PATH="$DSH_HOME_DIR/.credentials.yaml"
if [ -f "$CRED_PATH" ] && LC_ALL=C grep -Eq '^[[:space:]]*OPENROUTER_API_KEY[[:space:]]*:[[:space:]]*[^[:space:]]' "$CRED_PATH"; then
    ok 'OpenRouter API 키 확인 (.credentials.yaml)'
else
    warn 'OpenRouter API 키를 찾지 못했습니다.'
    info 'DSH 설정에서 OpenRouter 제공자에 API 키를 등록하세요(등록하면 .credentials.yaml 의 refs 에 저장됩니다).'
    info '또는 ~/.dsh/web-search.json 에 "api_key" 를 직접 넣거나 MCP 행의 env 로 DSH_WEB_SEARCH_API_KEY 를 넘길 수 있습니다.'
fi

# 앱 번들에 MCP 클라이언트가 있는지(설치 계속 진행, 경고만)
ASAR_CANDIDATES=""
if [ -n "${DSH_APP_ASAR:-}" ]; then
    ASAR_CANDIDATES="$DSH_APP_ASAR"
fi
ASAR_CANDIDATES="$ASAR_CANDIDATES
/Applications/DeepSeek Harness.app/Contents/Resources/app.asar
$HOME/Applications/DeepSeek Harness.app/Contents/Resources/app.asar"
ASAR_FOUND=""
_old_ifs=$IFS
IFS='
'
for _a in $ASAR_CANDIDATES; do
    [ -n "$_a" ] || continue
    if [ -f "$_a" ]; then
        ASAR_FOUND=$_a
        break
    fi
done
IFS=$_old_ifs
if [ -n "$ASAR_FOUND" ]; then
    if LC_ALL=C head -c 8388608 "$ASAR_FOUND" | LC_ALL=C grep -q 'dsh-mcp-client'; then
        ok 'DSH에 내장 MCP 클라이언트 확인 (dsh-mcp-client)'
    else
        warn 'app.asar 에서 dsh-mcp-client 를 찾지 못했습니다.'
        info '이 DSH 버전이 MCP를 지원하지 않으면 MCP 행은 로드되지 않습니다.'
    fi
else
    info 'app.asar 를 찾지 못해 MCP 지원 여부를 확인하지 못했습니다(설치는 계속 진행).'
    info '필요하면 DSH_APP_ASAR 환경변수로 경로를 지정하세요.'
fi

# ---------------------------------------------------------------- 5. 파일 설치

step '파일 설치'
TARGET_DIR="$DSH_HOME_DIR/mcp"
TARGET_SCRIPT="$TARGET_DIR/dsh-web-search.py"

yaml_quote() { printf '%s' "$1" | sed "s/'/''/g"; }
PY_YAML=$(yaml_quote "$PYTHON")
SCRIPT_YAML=$(yaml_quote "$TARGET_SCRIPT")
DSHHOME_YAML=$(yaml_quote "$DSH_HOME_DIR")

MANAGED_BLOCK=$(cat <<'BLOCK'
# >>> dsh-web-search-mcp managed block (do not edit) >>>
# install.sh 이 생성/관리합니다. 재실행하면 이 블록만 통째로 교체됩니다.
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
        # 이것이 없으면 서버가 ~/.dsh 로 폴백해, --dsh-home 으로 다른 홈을 지정한 설치에서
        # 자격증명과 설정 파일을 찾지 못한다.
        env:
          DSH_HOME: '__DSHHOME__'
        # 클라이언트 타임아웃은 서버 자체 타임아웃(검색 120s)보다 넉넉해야 한다.
        # 두 값이 같으면 클라이언트가 먼저 끊어 서버 오류를 보지 못한다.
        toolCallTimeoutMs: 180000
# <<< dsh-web-search-mcp managed block <<<
BLOCK
)
MANAGED_BLOCK=${MANAGED_BLOCK//__PYTHON__/$PY_YAML}
MANAGED_BLOCK=${MANAGED_BLOCK//__SCRIPT__/$SCRIPT_YAML}
MANAGED_BLOCK=${MANAGED_BLOCK//__DSHHOME__/$DSHHOME_YAML}

BLOCK_TMP=$(mktemp "${TMPDIR:-/tmp}/dsh-web-search-block.XXXXXX")
SECTION_TMP=$(mktemp "${TMPDIR:-/tmp}/dsh-web-search-agents.XXXXXX")
cleanup_tmp() { rm -f "$BLOCK_TMP" "$SECTION_TMP"; }
trap cleanup_tmp EXIT INT TERM
printf '%s\n' "$MANAGED_BLOCK" > "$BLOCK_TMP"
if [ -f "$SOURCE_AGENTS" ]; then
    cat "$SOURCE_AGENTS" > "$SECTION_TMP"
fi

# 5-1) 서버 스크립트
if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 복사: $SOURCE_SCRIPT -> $TARGET_SCRIPT"
else
    mkdir -p "$TARGET_DIR"
    cp -f "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
    ok "서버 스크립트 설치: $TARGET_SCRIPT"
fi

# 5-2) 프로파일 패치
if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 패치 갱신: $PATCH_PATH (기존 관리 블록/중복 id 정리 + 관리 블록 추가)"
    printf '\n%s----- 반영될 관리 블록 -----%s\n' "$C_GRAY" "$C_OFF"
    printf '%s\n' "$MANAGED_BLOCK"
else
    if [ -f "$PATCH_PATH" ]; then
        _stamp=$(date +%Y%m%d-%H%M%S)
        cp -f "$PATCH_PATH" "$PATCH_PATH.bak-$_stamp"
        ok "백업 생성: ${PATCH_PATH##*/}.bak-$_stamp"
    else
        info "패치 파일이 없어 새로 만듭니다: $PATCH_PATH"
        : > "$PATCH_PATH"
    fi
    _summary=$("$PYTHON" "$HELPER" patch-install "$PATCH_PATH" "$BLOCK_TMP")
    ok "프로파일 패치 갱신 ($_summary)"
fi

# 5-3) AGENTS.md
AGENTS_PATH="$DSH_HOME_DIR/AGENTS.md"
if [ "$NO_AGENTS" -eq 1 ]; then
    info 'AGENTS.md 설치는 건너뜀 (--no-agents)'
elif [ ! -f "$SOURCE_AGENTS" ]; then
    warn "템플릿을 찾지 못해 AGENTS.md 를 건너뜁니다: $SOURCE_AGENTS"
elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] AGENTS.md 갱신: $AGENTS_PATH"
else
    _summary=$("$PYTHON" "$HELPER" agents-install "$AGENTS_PATH" "$SECTION_TMP")
    case "$_summary" in
        updated) _agents_action='갱신' ;;
        cleaned) _agents_action='정리' ;;
        removed*) _agents_action='삭제(남은 내용 없음)' ;;
        absent) _agents_action='없음' ;;
        *) _agents_action=$_summary ;;
    esac
    ok "AGENTS.md $_agents_action : $AGENTS_PATH"
fi

# ---------------------------------------------------------------- 6. 검증

if [ "$SKIP_VERIFY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -f "$SCRIPT_DIR/verify.sh" ]; then
    step '자체 점검 (MCP stdio 프로브)'
    if ! bash "$SCRIPT_DIR/verify.sh" --dsh-home "$DSH_HOME_DIR" --python "$PYTHON" --profile "$PROFILE_NAME"; then
        warn '자체 점검이 실패했습니다. 위 출력을 확인하세요.'
    fi
fi

# ---------------------------------------------------------------- 7. 요약

printf '\n%s============================================================%s\n' "$C_CYAN" "$C_OFF"
printf '%s 설치 요약%s\n' "$C_CYAN" "$C_OFF"
printf '%s============================================================%s\n' "$C_CYAN" "$C_OFF"
info "DSH 홈        : $DSH_HOME_DIR"
info "프로파일      : $PROFILE_NAME"
info "패치 파일     : $PATCH_PATH"
info "서버 스크립트 : $TARGET_SCRIPT"
info "python        : $PYTHON"
info 'MCP 도구      : mcp__dsh-web-search__web_search, mcp__dsh-web-search__web_fetch'
info '검색 모델     : deepseek/deepseek-v4.1-flash (기본값)'
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s(dry-run 이었습니다: 파일을 쓰지 않았습니다)%s\n' "$C_YELLOW" "$C_OFF"
fi
printf '\n%s다음 단계:%s\n' "$C_YELLOW" "$C_OFF"
printf '%s  1) DSH를 완전히 종료한 뒤 다시 실행하세요.%s\n' "$C_YELLOW" "$C_OFF"
printf '%s  2) 새 대화에서 웹 검색을 요청하거나 다음으로 상태를 확인하세요:%s\n' "$C_YELLOW" "$C_OFF"
printf '%s     bash "%s/verify.sh" --search%s\n' "$C_YELLOW" "$SCRIPT_DIR" "$C_OFF"
printf '\n%s검색 모델/엔진 변경: ~/.dsh/web-search.json (examples/web-search.json 참고)%s\n' "$C_GRAY" "$C_OFF"
printf '%s제거: uninstall.sh%s\n' "$C_GRAY" "$C_OFF"
