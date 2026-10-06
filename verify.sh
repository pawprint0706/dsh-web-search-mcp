#!/usr/bin/env bash
#
# dsh-web-search-mcp 사후 점검 스크립트 (macOS / POSIX)
#
# 설치된 MCP 서버를 실제로 stdio 로 실행해 핸드셰이크와 도구 목록을 확인한다.
# --search 를 주면 실제 웹 검색까지 1회 수행한다(OpenRouter 호출이 발생하므로 소액 과금).
#
#   확인 항목:
#     1. 서버 스크립트 / python 존재
#     2. 프로파일 패치 정합성 (command 경로 / args 경로 / env DSH_HOME / 소스 SHA256)
#     3. initialize 핸드셰이크 (DSH MCP 클라이언트와 동일한 2025-era 협상)
#     4. tools/list (web_search, web_fetch)
#     5. DSH 쪽 MCP 자식 프로세스 실행 여부 (= DSH가 실제로 연결했는지)
#     6. (선택) tools/call web_search 실제 검색
#
# 사용법:
#   bash verify.sh
#   bash verify.sh --search --query "OpenRouter server tools"
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
SOURCE_SCRIPT="$SCRIPT_DIR/server/dsh-web-search.py"

DSH_HOME_ARG=""
PROFILE_ARG=""
PYTHON_ARG=""
DO_SEARCH=0
QUERY="DeepSeek Harness"
FAILURES=0

usage() {
    cat <<'USAGE'
dsh-web-search-mcp 점검 스크립트

사용법:
  bash verify.sh
  bash verify.sh --search --query "OpenRouter server tools"

옵션:
  --dsh-home <경로>   DSH 홈 (기본: $DSH_HOME, 그다음 ~/.dsh)
  --profile <이름>    프로파일 (기본: 자동 탐지)
  --python <경로>     사용할 python3 (기본: DSH 번들 런타임 → PATH)
  --search            실제 웹 검색까지 수행한다(OpenRouter 과금 발생)
  --query <검색어>    --search 의 검색어 (기본: DeepSeek Harness)
  -h, --help          이 도움말
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
        --search)     DO_SEARCH=1; shift ;;
        --query)      [ $# -ge 2 ] || { printf 'X --query 에 값이 필요합니다.\n' >&2; exit 2; }; QUERY=$2; shift 2 ;;
        --query=*)    QUERY=${1#*=}; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf 'X 알 수 없는 옵션: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

[ -f "$COMMON" ] || { printf '필수 파일이 없습니다: %s\n' "$COMMON" >&2; exit 1; }
# shellcheck source=tools/posix-common.sh
. "$COMMON"

count_failure() {
    fail "$1"
    FAILURES=$((FAILURES + 1))
}

printf '%s=== dsh-web-search-mcp 점검 ===%s\n' "$C_CYAN" "$C_OFF"

# ---------------------------------------------------------------- 경로

resolve_home "$DSH_HOME_ARG"
SCRIPT_PATH="$DSH_HOME_DIR/mcp/dsh-web-search.py"
info "DSH 홈: $DSH_HOME_DIR"

if [ ! -f "$SCRIPT_PATH" ]; then
    fail "서버 스크립트가 없습니다: $SCRIPT_PATH"
    info 'install.sh 을 먼저 실행하세요.'
    exit 1
fi
pass "서버 스크립트: $SCRIPT_PATH"

resolve_python "$DSH_HOME_DIR" "$PYTHON_ARG"
pass "python: $PYTHON"

# ---------------------------------------------------------------- 프로파일 패치 정합성

if resolve_profile "$DSH_HOME_DIR" "$PROFILE_ARG" 1; then
    PATCH_PATH="$PROFILE_DIR/cordis.patch.yml"
    PATCH_COMMAND=$("$PYTHON" "$HELPER" patch-get "$PATCH_PATH" command || true)
    PATCH_SCRIPT=$("$PYTHON" "$HELPER" patch-get "$PATCH_PATH" script || true)
    PATCH_DSHHOME=$("$PYTHON" "$HELPER" patch-get "$PATCH_PATH" dsh_home || true)

    if [ -z "$PATCH_COMMAND" ]; then
        count_failure '프로파일 패치의 관리 블록에서 command 를 찾지 못했습니다.'
        info 'install.sh 을 실행하세요.'
    else
        if [ -x "$PATCH_COMMAND" ]; then
            pass "패치 command 경로 확인: $PATCH_COMMAND"
            if [ "$PATCH_COMMAND" != "$PYTHON" ]; then
                info "탐지된 python 과 다릅니다(둘 다 유효): $PYTHON"
            fi
        else
            count_failure "패치의 command 경로가 존재하지 않습니다: $PATCH_COMMAND"
            info 'DSH 번들 런타임이 재생성된 것으로 보입니다. install.sh 을 다시 실행해 경로를 갱신하세요.'
        fi

        if [ -n "$PATCH_SCRIPT" ]; then
            if [ -f "$PATCH_SCRIPT" ]; then
                if [ "$PATCH_SCRIPT" != "$SCRIPT_PATH" ]; then
                    warn "패치의 args 경로가 설치 경로와 다릅니다: $PATCH_SCRIPT"
                else
                    pass "패치 args 경로 확인: $PATCH_SCRIPT"
                fi
            else
                count_failure "패치의 args 경로가 존재하지 않습니다: $PATCH_SCRIPT"
                info 'install.sh 을 다시 실행하세요.'
            fi
        fi

        if [ -n "$PATCH_DSHHOME" ]; then
            _patch_home=$(cd -- "$PATCH_DSHHOME" 2>/dev/null && pwd -P || printf '%s' "$PATCH_DSHHOME")
            if [ "$_patch_home" = "$DSH_HOME_DIR" ]; then
                pass "패치 env DSH_HOME 확인: $PATCH_DSHHOME"
            else
                count_failure "패치의 env DSH_HOME 이 이 DSH 홈과 다릅니다: $PATCH_DSHHOME (기대: $DSH_HOME_DIR)"
                info 'install.sh 을 다시 실행하세요.'
            fi
        else
            warn '패치에 env DSH_HOME 이 없습니다.'
            info 'DSH가 자식 프로세스 환경에서 DSH_* 를 제거하므로, 기본이 아닌 DSH 홈에서는 서버가 자격증명을 찾지 못합니다.'
        fi
    fi
else
    warn '프로파일을 찾지 못해 패치 정합성 점검을 건너뜁니다.'
fi

# 설치본이 이 프로젝트의 최신 소스와 같은지 (git pull 후 재설치 누락 감지)
if [ -f "$SOURCE_SCRIPT" ]; then
    if [ "$(file_sha256 "$SCRIPT_PATH")" = "$(file_sha256 "$SOURCE_SCRIPT")" ]; then
        pass '설치된 서버 스크립트 = 프로젝트 소스 (SHA256 일치)'
    else
        warn '설치된 서버 스크립트가 server/dsh-web-search.py 와 다릅니다.'
        info 'install.sh 을 다시 실행하면 최신 스크립트로 갱신됩니다.'
    fi
fi

# ---------------------------------------------------------------- 설정 상태

CRED_PATH="$DSH_HOME_DIR/.credentials.yaml"
if [ -f "$CRED_PATH" ] && LC_ALL=C grep -Eq '^[[:space:]]*OPENROUTER_API_KEY[[:space:]]*:[[:space:]]*[^[:space:]]' "$CRED_PATH"; then
    pass 'OpenRouter API 키 확인 (.credentials.yaml)'
else
    warn 'OpenRouter API 키를 찾지 못했습니다. 검색은 실패합니다.'
fi

CFG_PATH="$DSH_HOME_DIR/web-search.json"
if [ -f "$CFG_PATH" ]; then
    _model=$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8-sig")).get("model") or "deepseek/deepseek-v4.1-flash")' "$CFG_PATH" 2>/dev/null || printf 'deepseek/deepseek-v4.1-flash')
    info "검색 모델(web-search.json): $_model"
else
    info '검색 모델(기본값): deepseek/deepseek-v4.1-flash'
fi

# ---------------------------------------------------------------- stdio 프로브

OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/dsh-verify-out.XXXXXX")
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/dsh-verify-err.XXXXXX")
trap 'rm -f "$OUT_FILE" "$ERR_FILE"' EXIT INT TERM

REQ_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"dsh-verify","version":"1.0"}}}'
REQ_NOTE='{"jsonrpc":"2.0","method":"notifications/initialized"}'
REQ_TOOLS='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
REQ_SEARCH=""
if [ "$DO_SEARCH" -eq 1 ]; then
    _escaped_query=$(printf '%s' "$QUERY" | sed 's/\\/\\\\/g; s/"/\\"/g')
    REQ_SEARCH='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"'"$_escaped_query"'","max_results":3}}}'
fi

# 서버는 DSH_HOME 을 보고 자격증명/설정을 찾는다. DSH 본체는 자식 환경에서 DSH_* 를
# 제거하지만, 이 프로브는 직접 띄우므로 패치가 넘기는 것과 같은 값을 넘긴다.
set +e
DSH_HOME="$DSH_HOME_DIR" "$PYTHON" "$SCRIPT_PATH" >"$OUT_FILE" 2>"$ERR_FILE" <<PROBE_EOF
$REQ_INIT
$REQ_NOTE
$REQ_TOOLS
$REQ_SEARCH
PROBE_EOF
PROBE_STATUS=$?
set -e

PARSED=$("$PYTHON" - "$OUT_FILE" "$DO_SEARCH" <<'PARSE_EOF'
import json
import sys

path, want_search = sys.argv[1], sys.argv[2] == "1"
responses = {}
with open(path, encoding="utf-8", errors="replace") as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("id") is not None:
            responses[str(obj["id"])] = obj


def result_of(key):
    entry = responses.get(key) or {}
    result = entry.get("result")
    return result if isinstance(result, dict) else {}


init = result_of("1")
server_info = init.get("serverInfo") or {}
if init:
    print("\t".join(["INIT", str(init.get("protocolVersion", "")), str(server_info.get("name", "")), str(server_info.get("version", ""))]))
else:
    print("\t".join(["INIT", "", "", ""]))

tools = result_of("2").get("tools") or []
names = ",".join(str(tool.get("name", "")) for tool in tools if isinstance(tool, dict))
print("\t".join(["TOOLS", names]))

if want_search:
    entry = responses.get("3")
    if entry is None:
        print("\t".join(["SEARCH", "missing", "0", "0", ""]))
    else:
        result = entry.get("result") or {}
        content = result.get("content") or []
        text = ""
        if isinstance(content, list) and content and isinstance(content[0], dict):
            text = str(content[0].get("text") or "")
        citations = 0
        for raw in text.splitlines():
            stripped = raw.strip()
            if stripped.startswith("[") and "]" in stripped:
                label = stripped[1:stripped.index("]")]
                if label.isdigit():
                    citations += 1
        head = " / ".join([line for line in text.splitlines() if line.strip()][:4])
        state = "error" if result.get("isError") else "ok"
        print("\t".join(["SEARCH", state, str(len(text)), str(citations), head]))
PARSE_EOF
)

PROTO=""; SERVER_NAME=""; SERVER_VERSION=""; TOOL_NAMES=""
SEARCH_STATE=""; SEARCH_LEN=""; SEARCH_CITES=""; SEARCH_HEAD=""
while IFS=$'\t' read -r _key _a _b _c _d; do
    case "$_key" in
        INIT)   PROTO=$_a; SERVER_NAME=$_b; SERVER_VERSION=$_c ;;
        TOOLS)  TOOL_NAMES=$_a ;;
        SEARCH) SEARCH_STATE=$_a; SEARCH_LEN=$_b; SEARCH_CITES=$_c; SEARCH_HEAD=$_d ;;
    esac
done <<PARSED_EOF
$PARSED
PARSED_EOF

if [ -n "$PROTO" ]; then
    pass "initialize: protocolVersion=$PROTO, serverInfo=$SERVER_NAME v$SERVER_VERSION"
else
    count_failure 'initialize 응답이 없습니다.'
    if [ "$PROBE_STATUS" -ne 0 ]; then
        info "프로브 종료 코드: $PROBE_STATUS"
    fi
fi

case ",$TOOL_NAMES," in
    *,web_search,*) _has_search=1 ;;
    *) _has_search=0 ;;
esac
case ",$TOOL_NAMES," in
    *,web_fetch,*) _has_fetch=1 ;;
    *) _has_fetch=0 ;;
esac
if [ "$_has_search" = "1" ] && [ "$_has_fetch" = "1" ]; then
    pass "tools/list: $(printf '%s' "$TOOL_NAMES" | tr ',' ' ')"
else
    count_failure "tools/list 에 필요한 도구가 없습니다: ${TOOL_NAMES:-none}"
fi

# ---------------------------------------------------------------- DSH 쪽 연결 여부

CHILD_PIDS=""
HAVE_PGREP=0
if command -v pgrep >/dev/null 2>&1; then
    HAVE_PGREP=1
    CHILD_PIDS=$(pgrep -f "$SCRIPT_PATH" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)
    if [ -z "$CHILD_PIDS" ]; then
        _any=$(pgrep -f 'dsh-web-search.py' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)
        if [ -n "$_any" ]; then
            info '다른 경로의 dsh-web-search.py 프로세스가 실행 중입니다(이 설치가 아닐 수 있음).'
            CHILD_PIDS=$_any
        fi
    fi
fi
if [ "$HAVE_PGREP" -eq 0 ]; then
    info 'pgrep 이 없어 DSH 연결 여부를 확인하지 못했습니다.'
elif [ -n "$CHILD_PIDS" ]; then
    pass "DSH가 MCP 서버를 실행 중입니다 (PID $CHILD_PIDS)"
else
    warn 'DSH 쪽 MCP 자식 프로세스가 없습니다. DSH를 재시작했는지 확인하세요.'
fi

# ---------------------------------------------------------------- 실제 검색

if [ "$DO_SEARCH" -eq 1 ]; then
    case "$SEARCH_STATE" in
        ok)
            pass "web_search 성공: 응답 ${SEARCH_LEN}자, 출처 ${SEARCH_CITES}건"
            if [ -n "$SEARCH_HEAD" ]; then
                info "$SEARCH_HEAD"
            fi
            ;;
        error)
            count_failure "web_search 실패: $SEARCH_HEAD"
            ;;
        *)
            count_failure 'web_search 응답이 없습니다.'
            ;;
    esac
fi

# ---------------------------------------------------------------- 서버 stderr

if [ -s "$ERR_FILE" ]; then
    _log_lines=$(LC_ALL=C grep -F '[dsh-web-search]' "$ERR_FILE" || true)
    if [ -n "$_log_lines" ]; then
        printf '  %s--- 서버 stderr ---%s\n' "$C_GRAY" "$C_OFF"
        printf '%s\n' "$_log_lines" | while IFS= read -r _line; do
            printf '  %s%s%s\n' "$C_GRAY" "$_line" "$C_OFF"
        done
    fi
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf '%s결과: 정상%s\n' "$C_GREEN" "$C_OFF"
    exit 0
fi
printf '%s결과: 실패 %s 건%s\n' "$C_RED" "$FAILURES" "$C_OFF"
exit 1
