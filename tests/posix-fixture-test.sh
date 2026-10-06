#!/usr/bin/env bash
#
# macOS(POSIX) 설치 스크립트 픽스처 테스트.
#
# 실제 DSH 홈을 건드리지 않고 임시 DSH 홈을 만들어 install.sh → verify.sh →
# uninstall.sh 전체 흐름과 멱등성/정리를 검증한다. CI(macos-latest)에서 실행한다.
#
# 사용법: bash tests/posix-fixture-test.sh
#
# 실패하면 픽스처 경로를 출력하고 그대로 남겨 둔다(디버깅용).

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO_ROOT"

PASS_COUNT=0
FAIL_COUNT=0

# macOS 에는 sha256sum 이, Git bash 에는 shasum 이 없을 수 있어 python 을 쓴다.
hash_file() {
    "$REAL_PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

ok()   { printf '  [PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
note() { printf '  - %s\n' "$1"; }

assert_contains() { # <file> <pattern> <label>
    if LC_ALL=C grep -qF -- "$2" "$1"; then
        ok "$3"
    else
        bad "$3 ('$2' 를 $1 에서 찾지 못함)"
    fi
}

assert_not_contains() {
    if LC_ALL=C grep -qF -- "$2" "$1"; then
        bad "$3 ('$2' 가 $1 에 남아 있음)"
    else
        ok "$3"
    fi
}

# 실제 python3 (픽스처 런타임이 가리킬 대상)
REAL_PYTHON=$(command -v python3 || command -v python || true)
if [ -z "$REAL_PYTHON" ]; then
    printf 'python3 를 찾지 못했습니다.\n' >&2
    exit 1
fi

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/dsh-web-search-fixture.XXXXXX")
# install.sh 는 DSH 홈을 `pwd -P` 로 정규화한다. macOS 의 $TMPDIR 은 /var → /private/var
# 심볼릭 링크를 지나므로, 단언이 어긋나지 않도록 여기서도 같은 방식으로 정규화한다.
FIXTURE=$(cd -- "$FIXTURE" && pwd -P)
printf '픽스처: %s\n' "$FIXTURE"

# macOS(Darwin)에서는 install.sh 의 플랫폼 검사를 그대로 통과한다. 다른 플랫폼에서
# 이 테스트를 돌려볼 때만 의미가 있는 우회 플래그다.
export DSH_INSTALL_FORCE_PLATFORM=1

PROFILE_DIR="$FIXTURE/profiles/desktop"
PATCH_PATH="$PROFILE_DIR/cordis.patch.yml"
RUNTIME_BIN="$FIXTURE/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin"
mkdir -p "$PROFILE_DIR" "$RUNTIME_BIN" "$FIXTURE/mcp"

cat > "$PATCH_PATH" <<'EOF'
# 사용자 패치 레이어
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      openrouter:
        apiKeyEnv: OPENROUTER_API_KEY
- id: ui-theme
  name: "@deepseek-ai/dsh-client-ui-theme"
  config:
    fontSize: 18
EOF

cat > "$FIXTURE/.credentials.yaml" <<'EOF'
version: 1
refs:
  OPENROUTER_API_KEY: sk-or-v1-fixture-not-a-real-key
EOF

# macOS 런타임 규칙: dependencies/python/bin/python3
# (심볼릭 링크 권한이 없는 환경에서만 실행 래퍼로 대체한다 — 개발용 fallback)
if ! ln -sfn "$REAL_PYTHON" "$RUNTIME_BIN/python3" 2>/dev/null; then
    cat > "$RUNTIME_BIN/python3" <<WRAPPER
#!/usr/bin/env bash
exec "$REAL_PYTHON" "\$@"
WRAPPER
    chmod +x "$RUNTIME_BIN/python3"
fi

# 1) 설치
if bash install.sh --dsh-home "$FIXTURE" --skip-verify > "$FIXTURE/install.log" 2>&1; then
    ok 'install.sh 성공'
else
    bad 'install.sh 실패'
    cat "$FIXTURE/install.log"
fi

assert_contains "$PATCH_PATH" "$(printf '# >>> dsh-web-search-mcp managed block')" '패치에 관리 블록 추가'
assert_contains "$PATCH_PATH" '- id: web-search-deepseek' '내장 제공자 비활성화 행 추가'
assert_contains "$PATCH_PATH" 'serverName: dsh-web-search' 'MCP 서버 행 추가'
assert_contains "$PATCH_PATH" "command: '$RUNTIME_BIN/python3'" 'macOS 번들 런타임 python(bin/python3) 사용'
assert_contains "$PATCH_PATH" "DSH_HOME: '$FIXTURE'" 'env.DSH_HOME 전달'
assert_contains "$PATCH_PATH" 'toolCallTimeoutMs: 180000' '클라이언트 타임아웃 180000'
assert_contains "$PATCH_PATH" '- id: llm-pi-ai' '기존 사용자 행 보존(llm-pi-ai)'
assert_contains "$PATCH_PATH" '- id: ui-theme' '기존 사용자 행 보존(ui-theme)'

assert_contains "$FIXTURE/AGENTS.md" '<!-- dsh-web-search-mcp:begin -->' 'AGENTS.md 관리 섹션 추가'
assert_contains "$FIXTURE/AGENTS.md" 'mcp__dsh-web-search__web_search' 'AGENTS.md 도구 지침'

if [ -f "$FIXTURE/mcp/dsh-web-search.py" ]; then
    ok '서버 스크립트 설치'
else
    bad '서버 스크립트가 설치되지 않음'
fi

# 2) 멱등성
PATCH_HASH_BEFORE=$(hash_file "$PATCH_PATH")
AGENTS_HASH_BEFORE=$(hash_file "$FIXTURE/AGENTS.md")
bash install.sh --dsh-home "$FIXTURE" --skip-verify > "$FIXTURE/install2.log" 2>&1 || bad 'install.sh 재실행 실패'
if [ "$PATCH_HASH_BEFORE" = "$(hash_file "$PATCH_PATH")" ]; then
    ok '패치 멱등 (재실행 결과 동일)'
else
    bad '패치가 재실행에서 달라짐'
fi
if [ "$AGENTS_HASH_BEFORE" = "$(hash_file "$FIXTURE/AGENTS.md")" ]; then
    ok 'AGENTS.md 멱등 (재실행 결과 동일)'
else
    bad 'AGENTS.md 가 재실행에서 달라짐'
fi

# 3) verify.sh (무과금: 핸드셰이크 + 도구 목록까지)
if bash verify.sh --dsh-home "$FIXTURE" > "$FIXTURE/verify.log" 2>&1; then
    ok 'verify.sh exit 0'
else
    bad 'verify.sh 실패'
    cat "$FIXTURE/verify.log"
fi
assert_contains "$FIXTURE/verify.log" 'protocolVersion=2025-06-18' 'initialize 핸드셰이크'
assert_contains "$FIXTURE/verify.log" 'tools/list: web_search web_fetch' 'tools/list 확인'
assert_contains "$FIXTURE/verify.log" '패치 command 경로 확인' '패치 command 경로 정합성'
assert_contains "$FIXTURE/verify.log" 'DSH_HOME 확인' '패치 env DSH_HOME 정합성'
assert_contains "$FIXTURE/verify.log" 'SHA256 일치' '설치본/소스 SHA256 일치'
assert_contains "$FIXTURE/verify.log" '결과: 정상' 'verify 결과 정상'

# 4) 드리프트 감지 (command 경로가 사라진 경우)
mv "$RUNTIME_BIN/python3" "$RUNTIME_BIN/python3.moved"
if bash verify.sh --dsh-home "$FIXTURE" --python "$REAL_PYTHON" > "$FIXTURE/verify-drift.log" 2>&1; then
    bad '런타임이 사라졌는데 verify.sh 가 성공했다'
else
    ok '런타임 드리프트를 실패로 감지'
fi
assert_contains "$FIXTURE/verify-drift.log" 'command 경로가 존재하지 않습니다' '드리프트 안내 메시지'
mv "$RUNTIME_BIN/python3.moved" "$RUNTIME_BIN/python3"

# 5) 제거
if bash uninstall.sh --dsh-home "$FIXTURE" > "$FIXTURE/uninstall.log" 2>&1; then
    ok 'uninstall.sh 성공'
else
    bad 'uninstall.sh 실패'
    cat "$FIXTURE/uninstall.log"
fi
assert_not_contains "$PATCH_PATH" 'dsh-web-search-mcp managed block' '패치 관리 블록 제거'
assert_not_contains "$PATCH_PATH" 'mcp-dsh-web-search' 'MCP 행 제거'
assert_contains "$PATCH_PATH" '- id: llm-pi-ai' '제거 후 사용자 행 보존(llm-pi-ai)'
assert_contains "$PATCH_PATH" '- id: ui-theme' '제거 후 사용자 행 보존(ui-theme)'

if [ -f "$FIXTURE/AGENTS.md" ]; then
    bad 'AGENTS.md 가 남아 있음(내용이 없으면 삭제되어야 한다)'
else
    ok 'AGENTS.md 삭제(남은 내용 없음)'
fi
if [ -d "$FIXTURE/mcp" ]; then
    bad 'mcp 디렉터리가 남아 있음'
else
    ok 'mcp 디렉터리 삭제'
fi
if [ -f "$FIXTURE/.credentials.yaml" ]; then
    ok '사용자 자산(.credentials.yaml) 보존'
else
    bad '.credentials.yaml 이 삭제되었다'
fi

printf '\n결과: 통과 %d, 실패 %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
    printf '픽스처를 남겨 둡니다: %s\n' "$FIXTURE"
    exit 1
fi
rm -rf "$FIXTURE"
exit 0
