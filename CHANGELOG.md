# 변경 이력

## 1.3.0

macOS 지원 추가. Windows 경로(`install.ps1`/`verify.ps1`/`uninstall.ps1`)는 그대로 두고
같은 결과를 만드는 POSIX 스크립트를 별도로 제공한다.

- **신규 `install.sh` / `verify.sh` / `uninstall.sh`** — macOS(Darwin)용. bash 3.2(macOS 기본
  `/bin/bash`) 호환(연관 배열·`mapfile`·`${var,,}` 미사용). `--dsh-home`, `--profile`,
  `--python`, `--dry-run`, `--skip-verify`/`--no-agents`, `--search` 등 Windows 옵션과 대응.
  `install.sh` 는 다른 플랫폼에서 명시적으로 실패한다(테스트용
  `DSH_INSTALL_FORCE_PLATFORM=1` 우회 제공).
- **신규 `tools/cordis_patch.py`** — 패치/AGENTS.md 편집 로직을 테스트 가능한 python 으로 분리
  (`install.ps1` 이 PowerShell 로 하던 것과 같은 동작: 마커 블록 교체, 중복 id 제거,
  빈 `- insert:` 정리, 원본 줄바꿈 스타일 보존, 원자적 쓰기). `patch-get` 으로
  `verify.sh` 가 패치의 `command`/`args`/`env.DSH_HOME`/타임아웃을 읽는다.
- **신규 `tools/posix-common.sh`** — 세 셸 스크립트가 공유하는 홈/프로파일/python 해석과 출력.
  번들 런타임 python 경로 규칙을 플랫폼에 맞게 처리한다
  (macOS `dependencies/python/bin/python3`, Windows `python.exe`).
- **검증 강화**: `verify.sh` 도 Windows와 같은 항목을 점검한다 — 패치 정합성 4종
  (`command`/`args`/`env.DSH_HOME`/소스 SHA256), stdio 핸드셰이크, `tools/list`,
  DSH 자식 프로세스(`pgrep`), 선택적 실검색.
- **테스트**: `tests/test_cordis_patch.py`(편집기 단위 테스트 + 마커 일치 + 셸 스크립트
  BOM/CRLF 검사)와 `tests/posix-fixture-test.sh`(임시 DSH 홈으로 설치 → 멱등성 → 검증 →
  드리프트 감지 → 제거, 31개 단언). 단위 테스트 57 → **79개**.
- **CI**: `macos-latest` 잡 추가 — `bash -n` 구문 검사, 단위 테스트, 픽스처 설치/제거 테스트.
- **`.gitattributes`**: `*.sh text eol=lf`(셸 스크립트는 BOM 없는 LF).
- **문서**: macOS 설치/검증/제거 절차, 플랫폼별 옵션 대응표, 파일 구성, macOS 제약
  (`bin/python3`, Darwin 전용 게이트, Linux 미지원) 추가.

서버 본체(`server/dsh-web-search.py`)는 변경하지 않았다 — 두 플랫폼이 같은 서버를 쓴다.

## 1.2.1

- **서버: 낮은 심각도 결함 3건 수정** (`SERVER_VERSION` 1.1.1 → **1.1.2**).
  - `max_results` 를 1~10으로 **클램프**하도록 고쳤다. 기존에는 `0`/음수가 기본값(5)으로
    되돌아가 문서의 "1~10 클램프"와 어긋났다. 이제 `0`/음수는 경계값 1로, 정수로 해석할 수
    없는 값만 기본값으로 처리한다.
  - `plugin_fallback` 이 문자열 `"false"`/`"no"`/`"0"` 도 받아들인다(기존에는 `false`
    리터럴만 껐다).
  - `_html_to_text` 가 **닫히지 않은** `<script>`/`<style>`/`<noscript>` 를 문서 끝까지
    제거한다. 기존에는 짝이 맞는 블록만 지워, 미종료 블록의 JS/CSS 가 `web_fetch` 결과
    텍스트로 노출될 수 있었다.
- 테스트 55 → **57개**(클램프 경계·문자열 불리언·미종료 블록 회귀 추가).

## 1.2.0

- **서버: `base_url` 호스트 검사 강화** (`SERVER_VERSION` 1.1.0 → **1.1.1**).
  기존 `base_url.startswith("https://openrouter.ai")` 접두 검사는
  `https://openrouter.ai.evil.example/v1` 같은 유사 호스트를 통과시켜 **Bearer 토큰이
  제3자 호스트로 전송**될 수 있었다. 이제 `urlsplit` 으로 호스트를 정확히 비교해
  https + 호스트 `openrouter.ai`(포트 443/미지정)만 허용한다.
- **설치 드리프트 감지**: `verify.ps1` 이 프로파일 패치의 `command`/`args` 경로와, 설치본 대비
  `server/dsh-web-search.py` 의 SHA256을 검사한다. DSH가 번들 런타임을 재생성해 python
  절대경로가 어긋나는(가장 흔한) 실패 모드를 조용히 넘기지 않고 `install.ps1` 재실행을
  안내한다. `-Profile` 옵션 추가, `install.ps1` 이 프로파일명을 넘겨준다.
- **타임아웃 정합**: MCP 행의 `toolCallTimeoutMs` 를 120000 → **180000** 으로 올렸다.
  서버 자체 검색 타임아웃(120s)과 값이 같으면 클라이언트가 먼저 끊어 서버 오류를 보지 못한다.
- **uninstall 정리**: 서버 스크립트를 실행·임포트한 과정에서 남는
  `__pycache__/dsh-web-search*.pyc` 때문에 `mcp` 디렉터리가 지워지지 않던 문제를 수정
  (우리 모듈의 캐시만 골라 지운다).
- **`-DshHome` 지원 수정**: DSH는 자식 프로세스 환경에서 `DSH_*` 변수와
  `KEY`/`PASSWORD`/`SECRET`/`TOKEN` 이 든 변수를 모두 제거한다(`dsh-subprocess` 의
  `scrubbedParentEnv`). 그래서 MCP 행에 `env.DSH_HOME` 을 명시적으로 넣는다. 이것이 없으면
  서버가 `~/.dsh` 로 폴백해, `-DshHome` 으로 다른 홈을 지정한 설치에서 자격증명과
  `web-search.json` 을 찾지 못했다. `verify.ps1` 이 이 값도 검사하고, 프로브는 실제 실행과
  동일하게 `DSH_HOME` 을 넘겨 수행한다.
- **점검 정밀화**: `verify.ps1` 의 "DSH가 MCP 서버를 실행 중" 판정을 경로 기준으로 바꿔
  다른 DSH 홈에 설치된 사본을 이 설치로 오인하지 않게 했다.
- **`.editorconfig` 추가**: `.ps1` 을 UTF-8(BOM 포함)으로 저장하도록 고정한다(BOM이 없으면
  Windows PowerShell 5.1이 한글을 CP949로 오해석한다).
- **문서**: 9절 문제 해결에 드리프트 항목 2건 추가, `serverName ... already in use` 문구의
  성격(DSH 문서 근거이며 이 프로젝트에서 그대로 관측된 문구는 아님) 명시, 7절에 env 스크럽
  주의 추가, 11절 파일 구성 갱신, 12절의 "내장 `web_search` 가 남는 이유"를 정확화
  (`tool-web` 에 `search: false` 스위치는 있으나 프리셋 선언 행 전체 재진술이 필요해 미채택).
  검증 환경 DSH 표기 정정(제품 `version` 파일은 44.0.0, 하네스 런타임/peer 기준은 0.2.0-rc.2).
- **신규 `docs/dsh-internals.md`**: 프로필 합성과 `- insert:` 규칙, `ctx.web` provider seam
  계약, 웹 검색 스택 행 구성, MCP 클라이언트 계약과 env 스크럽, 자격증명, 미채택 대안을
  근거와 함께 기록.
- **신규 테스트/CI**: `tests/` 단위 테스트 + stdio 스모크 테스트(네트워크·과금 없음),
  PowerShell 스크립트 BOM·구문 검사, GitHub Actions(windows-latest).

## 1.1.0

- **deprecated 검색 경로 제거**: `plugins: [{id:"web"}]` 대신 OpenRouter 권장
  `tools: [{type:"openrouter:web_search"}]` 서버툴을 1순위로 사용.
- 서버툴은 모델이 검색 여부를 결정하므로, MCP 도구 계약("항상 검색")을 지키기 위해
  system 지시로 검색을 요구하고, 그래도 인용이 0건이면 레거시 플러그인으로 1회 폴백.
  플러그인이 제거된 이후에는 폴백이 조용히 건너뛰어진다.
- 설정 추가: `engine`, `max_uses`, `max_total_results`, `plugin_fallback`.
- 환경변수 추가: `DSH_WEB_SEARCH_ENGINE`.

## 1.0.0

- 최초 릴리스. DSH 내장 웹 검색이 OpenRouter에서 동작하지 않는 문제를 MCP stdio 서버로 우회.
- 도구: `web_search`(OpenRouter `web` 플러그인), `web_fetch`(직접 HTTP GET + HTML→text).
- 자격증명: `~/.dsh/.credentials.yaml` 의 `refs.OPENROUTER_API_KEY` 를 직접 읽음
  (DSH 하위 프로세스 env 스크럽 `*KEY*/*TOKEN*` 우회).
- 설치: `cordis.patch.yml` 에 `- insert:` 로 `@deepseek-ai/dsh-mcp-client` 행 추가,
  내장 `web-search-deepseek` 행 비활성화.