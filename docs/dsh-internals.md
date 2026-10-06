# DSH 내부 구조 조사 노트

이 문서는 **이 프로젝트를 유지보수하기 위해 알아야 하는 DSH 쪽 사실**을 기록한다.
다시 조사하지 않도록 근거와 함께 남긴다. 대상은 **DSH 44.0.0**(Windows x64,
`C:\Users\YCKIM\AppData\Local\Programs\DeepSeek Harness`)이다.

> **버전 표기 주의**: 앱 디렉터리의 `version` 파일 값은 **44.0.0** 이지만, 하네스 런타임
> 패키지(`@deepseek-ai/dsh-app-boot`)와 플러그인 peer 호환성 검사가 쓰는 값은
> **0.2.0-rc.2**(빌드 `04f392c9ddd144fa426da2045178797da6db6c11`)이다. 버전을 인용할 때는
> 어느 쪽인지 밝힌다.

## 0. app.asar 읽는 방법

하네스 코드는 `resources\app.asar`(약 121MB, 패킹) 안의 `dsh/` 트리에 있다.
`app.asar\dsh` 는 **실제 경로가 아니므로** 셸·`rg` 로는 읽히지 않는다
(`rg: 지정된 경로를 찾을 수 없습니다`). asar 헤더를 직접 파싱한다.

형식: 앞 16바이트 중 오프셋 12가 JSON 디렉터리 길이(`UInt32LE`)이고, 그 뒤 JSON,
데이터 시작 = `16 + jsonSize`. 파일 엔트리의 `offset`/`size` 가 **문자열로 올 수 있으므로
`Number()` 캐스팅이 필요**하다(캐스팅을 빼면 0바이트가 나온다).

```
node <asar-reader>.mjs list    "dsh/node_modules/@deepseek-ai"
node <asar-reader>.mjs cat     "dsh/node_modules/@deepseek-ai/dsh-base/cordis.patch.yml"
node <asar-reader>.mjs grep    "<정규식>" "dsh/node_modules/@deepseek-ai"
node <asar-reader>.mjs extract "dsh/node_modules/@deepseek-ai/dsh-web"
```

참고: `resources\app.asar.unpacked\dsh\node_modules` 에는 **네이티브 모듈만** 풀려 있다.
DSH가 앱 안에 넣어둔 자체 개발 스킬 문서(`dsh-agent-preset/skills/cordis-plugin-development`,
`.../editing-cordis-compositions`)도 이 방법으로 읽을 수 있다.

## 1. 프로필 합성과 패치 의미

- 프로필 루트: `~/.dsh/profiles/<profile>/`
  - `package.json` 의 `dsh.profile.bundles` = `["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]`
  - `cordis.yml` 은 `[]` 한 줄이고 "Edit cordis.patch.yml, not this file." 라고 적혀 있다.
  - `cordis.patch.yml` 이 사용자 패치 레이어다.
- 적용 순서: 각 번들의 패치 → 프로파일 `cordis.patch.yml` → `--patch` 오버레이.

**반드시 기억할 두 규칙**

1. **`- insert:` 규칙** — 프로파일 패치의 **최상위 `- id:` 는 기존 행에 대한 오버라이드로만
   해석된다.** 존재하지 않는 새 id를 최상위 `- id:` 로 쓰면 **조용히 무시**된다. 새 행은
   반드시 `- insert: [ { id, name, config } ]` 형태로 넣는다. (이 프로젝트의 MCP 등록이
   처음에 이 실수로 실패했다.)
2. **config 는 병합되지 않는다** — 패치는 행의 `config` 를 **통째로 교체**한다. 일부 키만
   적으면 나머지는 스키마 기본값이 된다.

**프리셋의 내부 행은 패치로 찌를 수 없다.** `preset-standard` 는
`@deepseek-ai/dsh-agent-preset` 선언 행이고, 그 `config.plugins` 안에 도구 행들이 들어 있다.
프로파일 패치가 `- id: preset-standard` 로 override하면 **`config` 전체가 교체**되므로
`plugins` 목록을 **전부 재진술**해야 한다(DSH 스킬 문서 `editing-cordis-compositions` 의
"Change a shipped preset" 절이 이 절차를 명시한다). 내부 행만 골라 바꾸는 방법은 없다.

## 2. 웹 검색 스택

`dsh-base/cordis.patch.yml` 이 다음 호스트 행들을 마운트한다.

| 행 id | 패키지 | 주요 config |
|---|---|---|
| `web` | `@deepseek-ai/dsh-web` | `searchProvider: deepseek-official`, `fetchProvider: http` |
| `web-search-deepseek` | `@deepseek-ai/dsh-web-search-deepseek` | `apiKeyEnv: DEEPSEEK_API_KEY` |
| `web-fetch-http` | `@deepseek-ai/dsh-web-fetch-http` | (없음) |
| `tool-web` | `@deepseek-ai/dsh-tool-web` | `{ fetch: true, searchTimeoutMs: 60000 }` |

`dsh-web-app/cordis.patch.yml` 은 호스트의 `tool-web` 을 `disabled: true` 로 끄고
(주석: "Web 표면은 여기서 끄고 각 세션이 프리셋을 마운트하게 한다"), 세션 프리셋
`presets/standard.patch.yml` 이 `tool-web` 을 `{ fetch: true, searchTimeoutMs: 60000 }` 로
다시 마운트한다. `minimal` 프리셋에는 `tool-web` 이 없다.

### `ctx.web` provider seam

`@deepseek-ai/dsh-web` 이 제공하는 서비스다. 검색과 fetch가 **하나의 서비스**를 공유하고,
provider는 두 개의 레지스트리로 나뉜다.

- `registerSearchProvider(provider)` / `registerFetchProvider(provider)`
- provider 계약: `{ id, available(), search(request, signal) }` (fetch는 fetch 쌍)
  - `available()` 은 **네트워크를 쓰지 않는 값싼 지역 검사**(예: API 키 존재)여야 한다.
  - 검색 요청은 `query`, `maxResults` 만 받고, 결과는 `{ sources[], content?, truncated? }`.
  - `maxResults` 는 **seam이 반환 후 잘라서** 강제한다(`capSources`).
- 선택 규칙(실행 시점 해석, 등록 순서 무관):

| 상황 | 결과 |
|---|---|
| 설정된 id가 등록·사용 가능 | 그 provider |
| 설정된 id 미등록 | `WEB_PROVIDER_CONFIGURED_MISSING` |
| 설정된 id 등록됐지만 unavailable | `WEB_PROVIDER_CONFIGURED_UNAVAILABLE` |
| id 없음 + 사용 가능 provider 1개 | 자동 선택 |
| id 없음 + 사용 가능 0개 | `WEB_PROVIDER_UNAVAILABLE` |
| id 없음 + 사용 가능 2개 이상 | `WEB_PROVIDER_AMBIGUOUS` |

- config 필드 `searchProvider`/`fetchProvider` 는 환경변수
  `DSH_WEB_SEARCH_PROVIDER`/`DSH_WEB_FETCH_PROVIDER` 와 동일한 필드를 채운다(숨은 우선순위 없음).
- 같은 id 중복 등록은 `WEB_DUPLICATE_PROVIDER` 로 거부된다.

### `dsh-tool-web` (모델 대면 도구)

`Config` 는 `{ search: bool(true), fetch: bool(true), searchMaxResults, searchMaxQueries,
searchTimeoutMs, fetchTimeoutMs }` 이고, 코드는 `if (resolved.search) applyWebSearchTool(...)`
형태다. 즉 **`search: false` 는 도구를 아예 등록하지 않는다.**
반대로 **활성화된 도구는 provider가 unavailable이어도 목록에 남는다** — 이것이
"제공자만 껐는데 실패하는 `web_search` 가 계속 보이는" 현상의 원인이다.

### 왜 내장 `web_search` 는 OpenRouter에서 동작하지 않는가

`@deepseek-ai/dsh-web-search-deepseek` 는 provider id `deepseek-official` 로 등록되고,
검색 시 다음을 보낸다.

```
POST {baseURL}/messages        # 기본 https://api.deepseek.com/anthropic/v1
{ model, max_tokens,
  messages: [{ role: "user", content: [{ type: "text", text: "Perform a web search for the query: …" }] }],
  tools: [{ type: "web_search_20250305", name: "web_search", max_uses }] }
```

응답 `content[]` 에서 `web_search_tool_result` 블록을 찾고, **없으면 `WebError`** 를 던진다.
즉 이 오류는 HTTP 실패가 아니라 **2xx + JSON 파싱 성공**을 전제로 한다.

실측 결론: OpenRouter의 Anthropic 호환 `/messages` 는 이 요청을 2xx + 유효 JSON으로
통과시키지만 `web_search_tool_result` 를 만들지 않는다. 모델을
`anthropic/claude-haiku-4.5` 로 바꿔도 동일했고, 세션 로그의
`web/deepseek-search-llm-request` 이벤트에 그 모델이 실제로 전송된 것이 기록되어
"패치가 로드되지 않았다"는 가설은 배제됐다. OpenRouter에서 검색을 실행하려면
`openrouter:web_search` 서버툴(권장) · `plugins:[{id:"web"}]`(deprecated) · `:online`
슬러그 중 하나를 써야 한다.

## 3. MCP 클라이언트

`@deepseek-ai/dsh-mcp-client` + `@deepseek-ai/dsh-mcp-resources` 가 앱 번들에 내장되어 있다
(**DSH는 MCP를 지원한다**). 기반 번들은 `mcp-resources` 만 마운트하고, 실제 MCP 서버 등록은
사용자 패치 엔트리로 추가한다.

- 공개 도구 이름: `mcp__<serverName>__<rawName>` (`serverName` 은 `[A-Za-z0-9_-]{1,32}`,
  같은 등록 스코프에서 유일해야 하며 **중복이면 후행 엔트리가 로드되지 않는다**).
- 엔트리 필드: `transport`(`stdio`|`streamable-http`), `serverName`, `command`/`args`/`env`/`cwd`,
  `url`/`headers`, `toolCallTimeoutMs`(기본 60000), `maxInstructionBytes`(32768),
  `failOnStartupError`(false), `reconnect.*`(enabled/initialDelayMs/maxDelayMs/maxAttempts).
- 자식 프로세스 환경은 `dsh-subprocess` 의 `scrubbedParentEnv()` 로 만들어진다.
  `SENSITIVE_ENV_PATTERN = /KEY|PASSWORD|SECRET|TOKEN/i` 에 **부분 일치**하는 이름과
  **`DSH_` 로 시작하는 모든 이름**이 제거된다(둘 다 대소문자 무시). `PATH`·`HOME`·로캘·프록시
  변수는 보존되고, 스펙에 **명시적으로 지정한 `env` 레이어는 스크럽 뒤에 병합**되므로 살아남는다.
  - 결과 1: **API 키를 환경변수로 넘길 수 없다.** 이 프로젝트가 `~/.dsh/.credentials.yaml`
    의 `refs` 를 직접 읽는 이유다.
  - 결과 2: **`DSH_HOME` 과 `DSH_WEB_SEARCH_*` 도 전달되지 않는다.** DSH 본체에 설정해 둬도
    MCP 자식은 보지 못하므로 MCP 행의 `env:` 로 명시해야 한다(설치 스크립트가 `DSH_HOME` 은
    항상 넣는다). `~/.dsh/web-search.json` 은 이 제약이 없다.
- 프로토콜 협상: SDK `@modelcontextprotocol/client@2.0.0` 의 기본 모드가 `legacy` 라서
  클라이언트가 요청한 버전이 지원 목록(`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`)에
  있으면 수용한다. 이 서버는 `2025-06-18` 로 응답한다.
- 서버 코드 교체는 **DSH 재시작 없이** 반영될 수 있다: 자식 프로세스가 종료되면
  클라이언트가 자동 재연결하며 새 코드로 기동한다.

## 4. 자격증명

- 저장소: `~/.dsh/.credentials.yaml` (`refs:` 아래 `이름: 값`).
  DSH는 `credentialRef('NAME')` / `ctx.credentials` 로 해석하고, 설정 UI에서 넣은 키가
  여기에 기록된다. `apiKeyEnv` 도 이 서비스를 통해 해석된다.
- 대화 모델 라우팅과 검색 자격증명은 **별개**다. 이 프로젝트는
  `refs.OPENROUTER_API_KEY` 를 직접 읽어 MCP 하위 프로세스에서 쓴다.
- 플러그인에서 쓰는 관용구: `credentialRef(config.apiKeyEnv)` →
  `ctx.get("credentials")?.resolve(ref)` → 폴백 `launchEnvironmentOf(ctx).get(ref)?.value`
  (`dsh-llm-pi-ai` 가 쓰는 패턴).

## 5. 이 프로젝트가 채택하지 않은 대안

| 대안 | 상태 |
|---|---|
| 내장 `web-search-deepseek` 의 `baseURL` 을 OpenRouter로 변경 | **불가** — OpenRouter가 `web_search_20250305` 를 실행하지 않음(모델 2종 실측) |
| `tool-web` 행을 `search: false` 로 override | **무효** — 실제 등록 주체는 프리셋 내부 행. 프리셋 선언 행 전체 재진술이 필요해 채택 안 함 |
| `ctx.web` 에 OpenRouter search provider를 등록하는 로컬 플러그인 | **의도적 미채택** — 2026-10-06 결정: **현재 MCP stdio 구조를 유지한다.** 되면 내장 도구가 살아나 MCP·Python·AGENTS 우회가 모두 불필요해지지만, 아래 5.1 의 위험(호스트 프로세스 코드 실행, DSH 내부 API 의존)을 감수하지 않기로 했다. 조사 결과는 참고용으로만 남긴다 |

### 5.1 네이티브 provider 플러그인 (정적 조사 결과)

**판정: 조건부 가능.** 프로필 패치의 `- insert:` 는 `name:` 에 **패치 파일 옆으로 앵커링되는
상대 경로**를 허용한다(`anchorInsertedPluginNames`). 그래서 npm/pnpm 설치나 `plugin_manager`
없이 **파일 1개 + 패치 몇 줄**로 로컬 플러그인을 마운트할 수 있다.

필요한 것:

1. **플러그인 파일** — `export const name`, `export const inject = ['web']`,
   `apply(ctx, config)` 에서 `ctx.web.registerSearchProvider({ id, available(), search(request, signal) })`.
   - provider 계약: `id`(레지스트리 키) / `available()`(동기·네트워크 금지) /
     `search()` → `{ sources: [{ url(필수), title?, snippet?, publishedAt? }], content?, truncated? }`.
   - `maxResults` 상한은 **seam이 반환 후 강제**한다(`capSources`). 요청 필드는 `query`, `maxResults` 뿐이다.
   - 실패는 `WebError` 로(코드는 열린 문자열): 키 없음 `WEB_PROVIDER_CREDENTIAL_MISSING`,
     취소 `WEB_ABORTED`, 그 밖 `WEB_PROVIDER_ERROR`. `signal` 을 fetch에 전달한다.
   - 구현할 로직은 기존 MCP 서버와 사실상 동일하다 — `chat/completions` +
     `tools:[{type:"openrouter:web_search"}]`, `annotations[].url_citation` → `sources`,
     `message.content` → `content`.
2. **`web` 행 오버라이드** — 기반이 `searchProvider: deepseek-official` 로 **고정**되어 있으므로
   `- id: web` + `config: { searchProvider: <새 id>, fetchProvider: http }` 로 **전체를 재진술**한다.
3. **새 행 insert** — `- insert: [ { id: web-search-<id>, name: './plugins/<dir>/index.js', config: {...} } ]`.

주의 / 미확인:

- 로컬 파일이 `@deepseek-ai/dsh-web` 을 **선언 없이 import해도** 앱 설치본 사본으로 해석된다
  (같은 모듈 인스턴스여야 `WebError` 정체성이 유지된다). peerDependencies를 쓰면 런타임
  버전 `0.2.0-rc.2` 와 맞춰야 하고, 비워 두면 preflight 검사를 피할 수 있다.
- 피어 `dsh.profile.bundles` 에 **로컬 경로를 직접 넣는 것은 불가**(npm 이름만 해석된다).
  `plugin_manager` 는 프로필에서 pnpm add + bundles 기록을 대신하는 도구이며, standard
  프리셋에서는 꺼져 있다(프리셋 내부 행이라 켜려면 프리셋 전체 재진술, 또는 Creator 모드로
  새 작업 열기).
- `!!js` 는 `new Function('ctx','expr','with (ctx) { return eval(expr) }')` 로 평가된다 —
  `process` 와 동기 builtin 모듈, `baseUrl` 에 접근할 수 있지만 `require` 는 주입되지 않는다.
  행 메타데이터(`name:`)는 리터럴이어야 한다.
- 설치한 플러그인은 **호스트 프로세스에서 코드를 실행**하므로 Full access/승인이 필요하다.
  DSH 업데이트로 seam 내부 API가 바뀌면 깨질 수 있다(접점이 2곳이라 수정 비용은 작다).
- **미검증**: 실제 마운트와 검색 성공은 확인하지 않았다(조사만 수행). 검증은 **새 세션**에서
  해야 한다 — 기존 세션은 시작 시점의 플러그인 리비전을 유지한다.

## 6. Web GUI의 플러그인 표면 — 왜 우리 MCP 서버가 목록에 안 보이는가

조사 시점: DSH 44.0.0(하네스 런타임 0.2.0-rc.2), Windows x64.
Web 클라이언트에는 플러그인 관련 표면이 셋뿐이고, **관리 단위는 모두 "번들"**이다.

| 위치 | 담당 패키지 | 다루는 것 |
|---|---|---|
| 사이드바 **Plugins** 페이지 | `dsh-client-ui-plugin-manager` | 프로필의 **번들** 관리 — 설치/켜기/끄기/삭제. 그룹은 **Official**(설치본이 제공하되 꺼둔 번들)과 **Installed**(프로필이 가진 번들) |
| Settings → **Built-in plugins** → *Plugin list* 탭 | `dsh-client-ui-settings-plugins` + `dsh-client-ui-settings-plugin-inventory` | **읽기 전용** 로더 인벤토리 — 에이전트 프리셋 구성(기본 펼침) + **global 평면(기본 접힘)** |
| 사이드바 Plugins → 각 플러그인 페이지 | `ui-settings-shell` / `-agent-loop` / `-subagent` / `-web-search` | 해당 플러그인의 config 폼. **`ui-settings-mcp` 같은 MCP 전용 페이지는 없다** |

핵심 근거(패키지 README 인용):

- `plugin-manager`: *"**Only bundles are managed** — a dependency without a bundle patch is
  refused before it installs; … **loading plain plugin modules stays a file operation**."*
  그리고 *"The page excludes built-in profile bundles from cards and counts even when the
  profile holds them as dependencies"*.
- `ui-settings-plugin-inventory`: `pluginInventory/list` 는 *"each non-group Loader entry"* 를
  투영한다 — 엔트리 id, 모듈 specifier, 유효 enablement(상위 그룹 disabled 포함), root fiber
  phase. **설정 화면을 열 때 1회 스냅샷**이고 변경 구독이 없으며 변이 기능도 없다.
- `dsh-host-plugin-inventory` 의 제약: *"**No layer attribution or mutation** — the service does
  not identify which bundle, profile, or override introduced an entry"*.

따라서 이 프로젝트의 설치 방식에는 다음이 따른다.

- 설치는 프로필 패치에 **raw 로더 행**만 넣는다(`- insert:` → id `mcp-dsh-web-search`,
  name `@deepseek-ai/dsh-mcp-client`). **번들이 아니므로** 사이드바 Plugins 페이지에는
  카드도, problem tag도 없이 **나타나지 않는다**(프로필 dependency로도 등록되어 있지 않다).
- 그 행은 **Settings → Built-in plugins → Plugin list 탭의 접힌 global 그룹**에서 읽기 전용으로
  보인다(검색: `mcp`, `dsh-mcp-client`). 표시되는 것은 엔트리 id·모듈 specifier·enablement·
  fiber phase뿐이고 편집이나 켜기/끄기 버튼은 없다.

설계 이유(정황 근거):

1. **번들이 생명주기 단위**다 — 설치/업그레이드/삭제는 pnpm 의존성 조작이고, 켜기/끄기는 레이어
   선택 + 프로필 패치의 `disabled` override다. 패키지 정체성이 없는 임의 행은 이 조작의 대상이
   될 수 없다.
2. **MCP는 기능이 아니라 한 플러그인의 설정**이다. DSH는 셸·에이전트 루프·서브에이전트·웹 검색
   각각에 전용 설정 페이지를 붙였지만, MCP 서버 목록을 GUI로 편집하는 화면은 두지 않았다.
3. **이 하네스에서 설치는 주로 에이전트가 수행**한다 — `plugin_manager` 는 모델 대면 도구이고
   (표준 프리셋에서는 `disabled: true`, Creator 모드에서 활성), 앱의 자체 스킬
   `cordis-plugin-development/references/mcp-bundle.md` 는 MCP 연결을 **설정 전용 번들**로
   만들어 `install_bundle` 로 설치하라고 안내한다.

### GUI에 노출시키고 싶다면 (미채택)

MCP 연결을 **설정 전용 번들**로 감싸면 사이드바 Plugins 에 **Installed** 카드로 나타나
켜기/끄기·행 단위 스위치·제거를 GUI에서 할 수 있다.

- `package.json`: 고유 `name`/`version` + `dsh.bundle.patch: ./cordis.patch.yml`
- `cordis.patch.yml`: 현재 관리 블록의 `- insert:` 행
- 설치: Plugins → **Add plugin** 에 **절대 로컬 경로** 입력(대화상자가 패키지명·Git 주소·
  tarball·절대 로컬 경로를 받는다) 또는 `plugin_manager` 의 `install_bundle`

2026-10-06 결정에 따라 채택하지 않았다 — 현재의 raw 행 방식은 `install.ps1` 만으로 끝나고
pnpm·프로필 의존성 상태를 요구하지 않는다(5절의 구조 결정과 같은 이유).

## 7. 운영 메모

- `command` 는 python 실행 파일의 **고정 절대경로**다. DSH가 번들 런타임을 재생성하면
  경로가 어긋나므로, `verify.ps1` 이 패치의 `command`/`args` 경로와 소스 SHA256을 검사해
  `install.ps1` 재실행을 안내한다.
- 프로파일 패치를 수정하기 전에는 항상 `.bak-<타임스탬프>` 백업이 생긴다(`install.ps1`/`uninstall.ps1`).
