# 변경 이력

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