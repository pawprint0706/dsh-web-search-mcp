# dsh-web-search-mcp

DSH(DeepSeek Harness)에서 **OpenRouter를 통해 웹 검색을 사용할 수 있게 해주는 MCP 서버 + 설치 스크립트**입니다.

DSH를 새로 설치한 환경에서도 스크립트 한 번으로 동일하게 구성할 수 있습니다.

---

## 1. 왜 필요한가

DSH의 내장 웹 검색 플러그인(`@deepseek-ai/dsh-web-search-deepseek`)은 검색을
**Anthropic Messages 엔드포인트(`/messages`)** 로 보내면서 서버사이드 도구
`web_search_20250305`를 지정합니다.

OpenRouter는 이 요청을 **2xx로 통과시키지만 도구를 실행하지 않습니다.** 그래서 응답에
`web_search_tool_result` 블록이 비어 돌아오고, DSH는 다음과 같이 실패합니다.

```
Error: DeepSeek returned no web_search_tool_result blocks;
the request may not have triggered native web search
```

DSH를 OpenRouter로 쓰는 환경(공식 DeepSeek 계정이 아닌 경우)에서는 이 경로를 고쳐도
동작하지 않습니다. 대신 **OpenRouter가 실제로 실행하는 검색 경로**를 MCP 도구로 노출하는
것이 이 프로젝트입니다.

## 2. 동작 원리

```
DSH ──(MCP stdio, JSON-RPC)──> dsh-web-search.py ──(HTTPS)──> OpenRouter
                                                              └ openrouter:web_search 서버툴
```

| 항목 | 내용 |
|---|---|
| MCP 서버 | `dsh-web-search.py` (Python 3.8+, 표준 라이브러리만 사용) |
| 공개 도구 이름 | `mcp__dsh-web-search__web_search`, `mcp__dsh-web-search__web_fetch` |
| 검색 경로 | `POST /api/v1/chat/completions` + `tools:[{type:"openrouter:web_search"}]` |
| 폴백 | 서버툴이 검색을 수행하지 않은 경우에만 레거시 `web` 플러그인으로 1회 재시도 |
| 자격증명 | `~/.dsh/.credentials.yaml` 의 `refs.OPENROUTER_API_KEY` (DSH 자체 저장소) |
| 기본 검색 모델 | `deepseek/deepseek-v4.1-flash` |

> **참고**: OpenRouter는 기존 `plugins:[{id:"web"}]` 방식을 deprecated 처리하고
> `openrouter:web_search` 서버툴을 권장합니다. 이 프로젝트는 권장 경로를 1순위로 쓰고,
> 폴백으로만 레거시 경로를 남겨둡니다(플러그인이 완전히 제거되어도 동작하도록).

## 3. 요구사항

- Windows + PowerShell 5.1 이상
- DSH가 **최소 한 번 실행**되어 `~/.dsh` 가 생성되어 있을 것
  (검증 환경: DSH **44.0.0**, Windows 10/11 x64)
- DSH에서 **OpenRouter 제공자에 API 키가 등록**되어 있을 것
  (DSH 설정 → 모델/API 키. 등록하면 `~/.dsh/.credentials.yaml` 의 `refs` 에 저장됩니다)
- Python 3.8+ — 없으면 DSH 번들 런타임(`~/.dsh/dsh-runtimes/.../python.exe`)을 자동 사용
- 스크립트는 **UTF-8(BOM 포함)** 으로 저장되어 있습니다. 직접 편집할 때 BOM을 유지하세요
  (Windows PowerShell 5.1은 BOM 없는 UTF-8의 한글을 CP949로 오해석해 구문 오류가 납니다).
  `tests/run-tests.ps1` 과 CI가 이 BOM과 구문 파싱을 검사합니다.

## 4. 빠른 설치

```powershell
cd C:\Projects\dsh-web-search-mcp
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

설치 후 **DSH를 완전히 종료했다가 다시 실행**하면 도구가 나타납니다.

### 설치 옵션

| 옵션 | 설명 |
|---|---|
| `-DshHome <경로>` | DSH 홈 지정(기본: `$env:DSH_HOME` 또는 `~/.dsh`) |
| `-Profile <이름>` | 프로파일 지정(기본: `cordis.patch.yml` 을 가진 프로파일 자동 탐지) |
| `-PythonPath <경로>` | MCP 서버를 실행할 python.exe 지정 |
| `-DryRun` | 파일을 쓰지 않고 계획만 출력 |
| `-SkipVerify` | 설치 후 자체 점검 생략 |
| `-NoAgents` | `AGENTS.md` 관리 섹션 설치 생략 |

## 5. 설치가 하는 일

| # | 대상 | 내용 |
|---|---|---|
| 1 | `<DSH_HOME>\mcp\dsh-web-search.py` | MCP 서버 스크립트 복사 |
| 2 | `<DSH_HOME>\AGENTS.md` | "웹 검색에는 `mcp__dsh-web-search__web_search` 를 쓴다"는 관리 섹션 추가/갱신 |
| 3 | `<DSH_HOME>\profiles\<profile>\cordis.patch.yml` | 관리 블록 추가(내장 제공자 비활성화 + MCP 행 삽입) |

추가되는 YAML 블록:

```yaml
# >>> dsh-web-search-mcp managed block (do not edit) >>>
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  disabled: true
- insert:
    - id: mcp-dsh-web-search
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: dsh-web-search
        transport: stdio
        command: '<python.exe 경로>'
        args:
          - '<DSH_HOME>\mcp\dsh-web-search.py'
        env:
          DSH_HOME: '<DSH_HOME>'
        toolCallTimeoutMs: 180000
# <<< dsh-web-search-mcp managed block <<<
```

> `env.DSH_HOME` 이 필요한 이유: DSH는 자식 프로세스 환경에서 **이름에
> `KEY`/`PASSWORD`/`SECRET`/`TOKEN` 이 들어간 변수와 `DSH_*` 변수를 모두 제거**한다
> (`dsh-subprocess` 의 `scrubbedParentEnv`). 그래서 이 값을 명시적으로 넘기지 않으면
> 서버가 `~/.dsh` 로 폴백해, `-DshHome` 으로 다른 홈을 지정한 설치에서 자격증명과
> `web-search.json` 을 찾지 못한다.

**안전장치**

- 수정 전 `cordis.patch.yml.bak-<타임스탬프>` 백업 생성
- **멱등**: 재실행하면 관리 블록만 교체됩니다
- 이전에 손으로 넣은 동일 id 항목(`mcp-dsh-web-search`, `web-search-deepseek`)은 자동 제거
  → **중복 등록(`serverName already in use`) 방지**
- UTF-8(BOM 없음)로 기록

## 6. 검증

```powershell
# 핸드셰이크 + 도구 목록 + DSH 연결 여부
powershell -ExecutionPolicy Bypass -File .\verify.ps1

# 실제 검색까지 수행 (OpenRouter 호출 = 소액 과금)
powershell -ExecutionPolicy Bypass -File .\verify.ps1 -Search -Query "OpenRouter server tools"
```

정상 출력 예:

```
=== dsh-web-search-mcp 점검 ===
  - DSH 홈: C:\Users\<user>\.dsh
  [PASS] 서버 스크립트: C:\Users\<user>\.dsh\mcp\dsh-web-search.py
  [PASS] python: ...\dependencies\python\python.exe
  [PASS] 패치 command 경로 확인: ...\dependencies\python\python.exe
  [PASS] 패치 args 경로 확인: C:\Users\<user>\.dsh\mcp\dsh-web-search.py
  [PASS] 설치된 서버 스크립트 = 프로젝트 소스 (SHA256 일치)
  [PASS] 패치 env DSH_HOME 확인: C:\Users\<user>\.dsh
  [PASS] OpenRouter API 키 확인 (.credentials.yaml)
  [PASS] initialize: protocolVersion=2025-06-18, serverInfo=dsh-web-search v1.1.2
  [PASS] tools/list: web_search, web_fetch
  [PASS] DSH가 MCP 서버를 실행 중입니다 (PID 12345)
  [PASS] web_search 성공: 응답 3749자, 출처 표기 6건
결과: 정상
```

점검 항목 중 **패치 정합성 4종**(`command` 경로 / `args` 경로 / `env.DSH_HOME` /
소스 SHA256)은 가장 흔한 실패 모드인 "DSH가 번들 런타임을 재생성해 python 절대경로가
어긋남"과 "다른 DSH 홈을 가리킴"을 잡기 위한 것입니다. 실패하면 `install.ps1` 재실행으로
복구됩니다.

DSH 안에서 직접 확인하려면 새 대화에서 웹 검색을 요청하거나, 도구 목록에
`mcp__dsh-web-search__web_search` 가 있는지 보면 됩니다.

### 자체 테스트 (선택, 과금 없음)

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

설치와 무관하게 표준 라이브러리만으로 도는 단위 테스트 + stdio 스모크 테스트
(핸드셰이크·도구 목록까지만, 검색 호출 없음) + PowerShell 스크립트 BOM·구문 검사를
수행합니다. `.github/workflows/ci.yml` 이 windows-latest에서 같은 검사를 돌립니다.

## 7. 설정 (선택)

`~/.dsh/web-search.json` 을 만들면 기본값을 바꿀 수 있습니다
(`examples/web-search.json` 참고).

```json
{
  "model": "deepseek/deepseek-v4.1-flash",
  "engine": "auto",
  "max_results": 5,
  "max_total_results": 15,
  "max_uses": 3,
  "plugin_fallback": true
}
```

| 키 | 기본값 | 설명 |
|---|---|---|
| `model` | `deepseek/deepseek-v4.1-flash` | 검색 결과를 요약·인용하는 모델 |
| `engine` | `auto` | `auto`/`native`/`exa`/`firecrawl`/`parallel`/`perplexity` |
| `max_results` | `5` | 검색 1회당 결과 수. 숫자는 1–10으로 클램프(0·음수는 1), 정수로 해석 불가면 기본값 |
| `max_total_results` | 없음 | 요청 전체 누적 결과 상한(비용·컨텍스트 제어) |
| `max_uses` | 없음 | 모델이 수행할 수 있는 검색 횟수 상한 |
| `plugin_fallback` | `true` | 서버툴이 검색하지 않았을 때 레거시 플러그인 폴백 사용(`false`/`"false"`/`"no"`/`"0"` 모두 인식) |
| `base_url` | `https://openrouter.ai/api/v1` | OpenRouter 전용. **호스트가 정확히 `openrouter.ai` 인 https URL만 허용**(유사 호스트·다른 포트·http 는 거부) |
| `api_key` | 없음 | 직접 키 지정(미지정 시 `.credentials.yaml` 사용) |

환경변수로도 지정할 수 있습니다:
`DSH_WEB_SEARCH_MODEL`, `DSH_WEB_SEARCH_ENGINE`, `DSH_WEB_SEARCH_MAX_RESULTS`,
`DSH_WEB_SEARCH_API_KEY`, `DSH_WEB_SEARCH_BASE_URL`, `DSH_HOME`

> **주의**: DSH는 MCP 자식 프로세스의 환경에서 **`DSH_*` 변수와
> 이름에 `KEY`/`PASSWORD`/`SECRET`/`TOKEN` 이 들어간 변수를 제거**합니다
> (`scrubbedParentEnv`). 따라서 DSH 본체에 이 변수들을 설정해 두는 것만으로는
> 서버에 전달되지 않습니다. 환경변수로 지정하려면 위 설치 YAML 의 MCP 행에
> `env:` 를 추가해 **명시적으로 넘기세요**(설치 스크립트가 `DSH_HOME` 은 항상 넣습니다).
> `~/.dsh/web-search.json` 은 이 제약이 없어 가장 확실한 방법입니다.

### 검색 모델에 대해

검색(엔진 조회·본문 수집)은 **OpenRouter 서버사이드**가 수행하고, 그 결과를 받아
**요약·인용을 생성하는 모델**이 `model` 값입니다. DeepSeek 모델은 네이티브 검색이 없어
`engine: auto` 로 두면 Exa가 사용됩니다. 비용을 조이려면 `max_total_results`/`max_uses`를 쓰세요.

검색 비용은 **모델 토큰 비용과 별개로** 부과됩니다(엔진별 단가, OpenRouter 문서 기준).

| 엔진 | 단가 | 비고 |
|---|---|---|
| `exa` (auto의 기본 폴백) | $0.007/요청 | 결과 10건 포함, 초과분 $0.001/건 |
| `parallel` | $0.001~0.005/요청 | 결과 10건 포함 |
| `perplexity` | $0.005/요청 | |
| `firecrawl` | OpenRouter 과금 없음 | 본인 Firecrawl 크레딧 사용(BYOK) |
| `native` | 제공자 과금 | OpenAI/Anthropic/Google/Perplexity/xAI 내장 검색 |

서버툴은 모델이 검색 횟수를 정하므로(0~N회) 한 요청에서 여러 번 과금될 수 있습니다.

## 8. 수동 설치 (PowerShell 없이 / 타 OS)

1. `server/dsh-web-search.py` 를 `~/.dsh/mcp/dsh-web-search.py` 로 복사
2. `~/.dsh/AGENTS.md` 에 `templates/AGENTS.md` 내용을 추가
3. `~/.dsh/profiles/<profile>/cordis.patch.yml` 끝에 아래 블록 추가
   (`<PYTHON>` 은 python 실행 파일, `<SCRIPT>` 는 1번 경로, `<DSH_HOME>` 은 DSH 홈)

```yaml
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  disabled: true
- insert:
    - id: mcp-dsh-web-search
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: dsh-web-search
        transport: stdio
        command: '<PYTHON>'
        args:
          - '<SCRIPT>'
        env:
          DSH_HOME: '<DSH_HOME>'
        toolCallTimeoutMs: 180000
```

> **YAML 문법 주의 (중요)**
> - **새 행은 반드시 `- insert:` 리스트 안에** 넣어야 합니다. 최상위 `- id: <새 id>` 형태로
>   쓰면 "존재하는 행에 대한 오버라이드"로 해석되어 **조용히 무시**됩니다.
> - 패치는 행의 `config` 를 **병합하지 않고 통째로 교체**합니다. 일부 키만 적으면 나머지는
>   스키마 기본값이 됩니다.
> - 경로는 작은따옴표로 감싸세요(YAML에서 백슬래시 이스케이프 문제 방지).
> - 들여쓰기에 탭을 쓰지 마세요.

## 9. 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| 도구 목록에 `mcp__dsh-web-search__*` 가 없음 | DSH를 재시작하지 않음 → 재시작. 그래도 없으면 `verify.ps1` 로 서버 자체를 확인 |
| `verify.ps1` 에서 `DSH가 MCP 서버를 실행 중입니다` 가 `[!]` | DSH가 연결하지 못함 → `cordis.patch.yml` 의 `command`/`args` 경로 확인(따옴표·역슬래시) |
| `패치의 command 경로가 존재하지 않습니다` (`verify.ps1`) | DSH가 번들 런타임을 재생성함 → `install.ps1` 재실행으로 경로 갱신 |
| `설치된 서버 스크립트가 server\dsh-web-search.py 와 다릅니다` (`verify.ps1`) | `git pull` 후 재설치 누락 → `install.ps1` 재실행 |
| `serverName "dsh-web-search" is already in use` | `mcp-dsh-web-search` 행이 중복. DSH MCP 클라이언트는 같은 스코프에서 중복 `serverName`이면 후행 엔트리를 로드하지 않습니다(DSH 문서 규칙 — 이 프로젝트에서 그대로 관측된 문구는 아닙니다) → `install.ps1` 재실행(중복 자동 정리) 또는 중복 행 삭제 |
| 검색이 `configured web provider "deepseek-official" is not registered` | 내장 `web_search` 도구를 호출한 것 → `mcp__dsh-web-search__web_search` 사용(관리 블록이 내장 제공자를 비활성화한 상태이며 이는 정상) |
| `OpenRouter 토큰을 찾지 못했습니다` | DSH 설정에서 OpenRouter API 키 등록, 또는 `web-search.json` 의 `api_key`, 또는 `DSH_WEB_SEARCH_API_KEY` |
| `OpenRouter 오류: ...` | 키/크레딧/모델명 확인. `engine` 을 `exa` 로 명시해 보세요 |
| DSH가 부팅되지 않음 | `cordis.patch.yml.bak-<타임스탬프>` 로 복원 후, YAML 문법(탭/따옴표) 확인 |
| python 경로가 바뀜(DSH 런타임 재생성) | `install.ps1` 재실행으로 `command` 경로 갱신 |

## 10. 제거

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

관리 블록/AGENTS.md 관리 섹션/설치된 스크립트를 제거합니다(백업 생성).
`~/.dsh/web-search.json` 과 `.credentials.yaml` 은 유지됩니다.

## 11. 파일 구성

```
dsh-web-search-mcp/
├─ install.ps1                 설치 (멱등)
├─ uninstall.ps1               제거
├─ verify.ps1                  사후 점검 (stdio 프로브 + 패치 정합성)
├─ server/
│   └─ dsh-web-search.py       MCP 서버 본체
├─ templates/
│   └─ AGENTS.md               전역 지침 템플릿
├─ examples/
│   └─ web-search.json         선택 설정 예시
├─ docs/
│   └─ dsh-internals.md        DSH 내부 구조 조사 노트 (행 구성·provider seam)
├─ tests/                      단위 테스트 + stdio 스모크 테스트
├─ .github/workflows/ci.yml    CI (windows-latest)
├─ CHANGELOG.md
└─ README.md
```

## 12. 알려진 제약

- **내장 `web_search` 도구는 여전히 목록에 남습니다.** 실제 등록 주체는 앱 번들 안의
  에이전트 프리셋(`preset-standard` → `config.plugins` **내부 행**)이라 프로파일 패치가
  id로 직접 찌를 수 없습니다. `tool-web` 항목에는 등록 자체를 끄는 `search: false`
  스위치가 있지만, 쓰려면 프리셋 선언 행(`preset-standard`)의 `plugins` 목록 **전체를
  재진술**해야 하고 그 목록은 DSH 버전마다 바뀌므로 채택하지 않았습니다
  (직접 override를 시도했다가 되돌린 이력이 있습니다 — `docs/dsh-internals.md` 참고).
  다만 제공자가 비활성화되어 **API 호출 없이 즉시 실패**하므로 비용·지연 손실은 없습니다.
  `AGENTS.md` 지침이 모델을 MCP 도구로 유도합니다.
- `command` 는 python 실행 파일의 **고정 경로**입니다. DSH가 번들 런타임을 재생성하면
  `install.ps1` 재실행이 필요할 수 있습니다.
- DSH MCP 클라이언트는 기본 협상 모드가 `legacy`(2025-era)이므로 서버는
  `2025-06-18` 로 응답합니다(클라이언트 지원 목록에 포함되어 정상 연결).
- macOS/Linux 는 `install.ps1` 대신 **8. 수동 설치** 절차를 사용하세요.

---

버전: **1.2.1** (MCP 서버 내부 버전 `SERVER_VERSION` = 1.1.2) ·
자세한 변경 이력은 [CHANGELOG.md](CHANGELOG.md)