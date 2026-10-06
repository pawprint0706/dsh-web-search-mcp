# 변경 이력

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