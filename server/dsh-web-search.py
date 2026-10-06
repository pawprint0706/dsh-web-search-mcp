#!/usr/bin/env python3
"""DeepSeek Harness - provider-native web search MCP server (zero dependency).

DSH의 내장 웹 검색 플러그인(dsh-web-search-deepseek)은 서버사이드 검색 도구
(web_search_20250305)를 /messages 엔드포인트로 보내는데, OpenRouter는 이 도구
유형을 실행하지 않는다(요청은 2xx로 통과하지만 결과 블록이 비어 돌아온다).
이 서버는 OpenRouter가 실제로 지원하는 경로로 web_search / web_fetch를 대체
제공한다.

  - search(1순위): chat/completions + `openrouter:web_search` 서버툴
                   (권장 경로. 모델이 검색 시점을 결정한다)
  - search(폴백) : 서버툴이 검색을 수행하지 않은 경우에만 레거시 `web` 플러그인
                   (deprecated)으로 1회 재시도한다. 플러그인이 제거되면 폴백은
                   조용히 건너뛰고 서버툴 응답을 그대로 반환한다.
  - fetch        : 직접 HTTP GET 후 HTML을 텍스트로 변환

자격증명/모델 해석 순서는 resolve_config() 참조. DSH 자체 저장소
(~/.dsh/.credentials.yaml)만 사용하며 외부 도구 설정에 의존하지 않는다.

프로토콜: MCP stdio (JSON-RPC 2.0, newline-delimited).
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

SERVER_NAME = "dsh-web-search"
SERVER_VERSION = "1.1.0"

# DSH MCP 클라이언트(@modelcontextprotocol/client 2.0.0)는 기본 협상 모드가
# "legacy"라서 2025-era initialize 핸드셰이크를 수행한다. 서버가 돌려준
# protocolVersion이 클라이언트의 SUPPORTED 목록(2025-11-25, 2025-06-18,
# 2025-03-26, 2024-11-05)에 있으면 연결이 성립한다.
KNOWN_PROTOCOL_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18"}
LATEST_PROTOCOL_VERSION = "2025-06-18"

DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_SEARCH_MODEL = "deepseek/deepseek-v4.1-flash"
DEFAULT_SEARCH_ENGINE = "auto"
DEFAULT_MAX_RESULTS = 5
MAX_CONTENT_CHARS = 20000
PLACEHOLDER_KEYS = {"", "YOUR-API-KEY-HERE", "changeme"}

# 서버툴은 모델이 검색 여부를 스스로 결정하므로, MCP 도구 계약("항상 검색")을
# 지키기 위해 검색을 명시적으로 요구한다.
SEARCH_SYSTEM_PROMPT = (
    "You are answering a web-search request. You MUST call the web search tool at "
    "least once before answering so the answer is grounded in current sources. "
    "Then answer concisely and cite the sources you used."
)

TOOLS = [
    {
        "name": "web_search",
        "description": (
            "웹 검색. OpenRouter의 서버사이드 웹 검색(openrouter:web_search)으로 "
            "검색하고 출처(URL 인용)와 요약 본문을 반환한다."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "검색어"},
                "max_results": {
                    "type": "integer",
                    "description": f"가져올 출처 수 (기본 {DEFAULT_MAX_RESULTS}, 1-10)",
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "web_fetch",
        "description": "URL의 본문을 텍스트로 읽어온다. HTML이면 태그를 제거해 반환한다.",
        "inputSchema": {
            "type": "object",
            "properties": {"url": {"type": "string", "description": "읽을 URL"}},
            "required": ["url"],
            "additionalProperties": False,
        },
    },
]


class _Redirect308Handler(urllib.request.HTTPRedirectHandler):
    """urllib 기본 핸들러는 308 Permanent Redirect를 처리하지 않아 직접 추가한다."""

    def http_error_308(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)


# ---------------------------------------------------------------- JSON-RPC


def _result(msg_id, result):
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _error(msg_id, code, message):
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def handle_message(msg, state):
    """메시지 1건을 처리한다. 응답 dict 또는 None(notification)을 반환."""
    if not isinstance(msg, dict):
        return _error(None, -32600, "Invalid request")
    method = str(msg.get("method") or "")
    if method.startswith("notifications/"):
        return None
    if "id" not in msg:
        return None
    msg_id = msg["id"]
    if method == "initialize":
        requested = str((msg.get("params") or {}).get("protocolVersion") or "")
        return _result(
            msg_id,
            {
                "protocolVersion": (
                    requested
                    if requested in KNOWN_PROTOCOL_VERSIONS
                    else LATEST_PROTOCOL_VERSION
                ),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )
    if method == "ping":
        return _result(msg_id, {})
    if method == "tools/list":
        return _result(msg_id, {"tools": TOOLS})
    if method == "resources/list":
        return _result(msg_id, {"resources": []})
    if method == "prompts/list":
        return _result(msg_id, {"prompts": []})
    if method == "tools/call":
        return _tool_call(msg, msg_id, state)
    return _error(msg_id, -32601, f"Method not found: {method}")


def _tool_call(msg, msg_id, state):
    params = msg.get("params") or {}
    name = str(params.get("name") or "")
    args = params.get("arguments")
    if not isinstance(args, dict):
        args = {}
    try:
        if name == "web_search":
            text = _run_search(args, state)
        elif name == "web_fetch":
            text = _run_fetch(args, state)
        else:
            return _result(
                msg_id,
                {
                    "content": [{"type": "text", "text": f"알 수 없는 도구입니다: {name}"}],
                    "isError": True,
                },
            )
        return _result(msg_id, {"content": [{"type": "text", "text": text}], "isError": False})
    except Exception as exc:
        # 도구 실행 실패는 JSON-RPC 에러가 아니라 isError=True 결과로 보고한다 (MCP 규격).
        return _result(
            msg_id,
            {"content": [{"type": "text", "text": f"오류: {exc}"}], "isError": True},
        )


def main() -> None:
    # Windows 파이프 환경에서는 stdout 기본 인코딩이 레거시 코드페이지(cp949)라서
    # 응답에 비ASCII 문자가 섞이면 UnicodeEncodeError로 프로세스가 죽는다.
    # stdio MCP 응답이므로 항상 UTF-8로 내보낸다.
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    state: dict = {}
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            _write(_error(None, -32700, f"Parse error: {exc}"))
            continue
        _reply(msg, state)


def _reply(msg, state) -> None:
    try:
        response = handle_message(msg, state)
    except Exception as exc:
        response = _error(
            msg.get("id") if isinstance(msg, dict) else None,
            -32603,
            f"Internal error: {exc}",
        )
    if response is not None:
        _write(response)


def _write(obj) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _log(text: str) -> None:
    sys.stderr.write(f"[{SERVER_NAME}] {text}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------- 설정 해석


def _dsh_home() -> Path:
    override = os.environ.get("DSH_HOME")
    return Path(override).expanduser() if override else Path.home() / ".dsh"


def _read_json(path: Path):
    try:
        with path.open("r", encoding="utf-8-sig") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError):
        return None


def _credentials_refs() -> dict:
    """~/.dsh/.credentials.yaml의 refs 섹션을 의존성 없이 훑어 NAME: value를 뽑는다."""
    path = _dsh_home() / ".credentials.yaml"
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return {}
    refs: dict = {}
    inside = False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        stripped = raw.strip()
        if indent == 0:
            inside = stripped.startswith("refs:")
            continue
        if not inside:
            continue
        key, _, value = stripped.partition(":")
        value = value.strip().strip('"').strip("'")
        if key.strip() and value:
            refs[key.strip()] = value
    return refs


def _user_config() -> dict:
    """선택적 사용자 설정: ~/.dsh/web-search.json"""
    cfg = _read_json(_dsh_home() / "web-search.json")
    return cfg if isinstance(cfg, dict) else {}


def _positive_int(value, default):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def resolve_config():
    """(token, model, base_url, options, error) 튜플. 실패 시 error에 한국어 안내."""
    cfg = _user_config()

    base_url = (
        os.environ.get("DSH_WEB_SEARCH_BASE_URL")
        or str(cfg.get("base_url") or "")
        or DEFAULT_BASE_URL
    ).strip().rstrip("/")

    model = (
        os.environ.get("DSH_WEB_SEARCH_MODEL")
        or str(cfg.get("model") or "")
        or DEFAULT_SEARCH_MODEL
    ).strip()

    options = {
        "max_results": min(
            max(
                _positive_int(
                    os.environ.get("DSH_WEB_SEARCH_MAX_RESULTS")
                    or cfg.get("max_results"),
                    DEFAULT_MAX_RESULTS,
                ),
                1,
            ),
            10,
        ),
        "engine": (
            os.environ.get("DSH_WEB_SEARCH_ENGINE")
            or str(cfg.get("engine") or "")
            or DEFAULT_SEARCH_ENGINE
        ).strip(),
        # 선택: 서버툴 검색 예산 상한 (미설정 시 OpenRouter 기본 동작)
        "max_uses": _positive_int(cfg.get("max_uses"), 0),
        "max_total_results": _positive_int(cfg.get("max_total_results"), 0),
        # 레거시 web 플러그인 폴백 사용 여부
        "plugin_fallback": cfg.get("plugin_fallback", True) is not False,
    }

    token = (
        os.environ.get("DSH_WEB_SEARCH_API_KEY")
        or os.environ.get("OPENROUTER_API_KEY")
        or str(cfg.get("api_key") or "")
        or str(_credentials_refs().get("OPENROUTER_API_KEY") or "")
    ).strip()

    if not base_url.startswith("https://openrouter.ai"):
        return "", "", "", options, (
            f"OpenRouter 전용입니다: base_url='{base_url or '(없음)'}'에서는 "
            "웹 검색 백엔드를 사용할 수 없습니다."
        )
    if token in PLACEHOLDER_KEYS:
        return "", "", "", options, (
            "OpenRouter 토큰을 찾지 못했습니다. DSH 설정에서 OpenRouter API 키를 "
            "등록하거나 DSH_WEB_SEARCH_API_KEY 환경변수로 전달하세요."
        )
    if not model:
        return "", "", "", options, "검색에 사용할 모델명이 비어 있습니다."
    return token, model, base_url, options, ""


# ---------------------------------------------------------------- 백엔드


def _post_json(url: str, payload: dict, token: str, timeout: int = 120):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def _get_text(url: str, timeout: int = 60):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}",
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
        },
    )
    opener = urllib.request.build_opener(_Redirect308Handler())
    with opener.open(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def _clip(text: str, limit: int) -> str:
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[:limit] + " ...(truncated)"


def _run_search(args: dict, _state: dict) -> str:
    query = str(args.get("query") or "").strip()
    if not query:
        raise ValueError("검색어(query)가 비어 있습니다.")
    token, model, base_url, options, error = resolve_config()
    if error:
        raise RuntimeError(error)
    max_results = options["max_results"]
    requested = args.get("max_results")
    if isinstance(requested, int) and not isinstance(requested, bool):
        max_results = min(max(requested, 1), 10)
    return _search_openrouter(query, token, model, base_url, max_results, options)


def _run_fetch(args: dict, _state: dict) -> str:
    url = str(args.get("url") or "").strip()
    if not url:
        raise ValueError("URL이 비어 있습니다.")
    if not re.match(r"^https?://", url, re.I):
        raise ValueError("http(s) URL만 지원합니다.")
    return _fetch(url)


def _raise_on_api_error(data) -> None:
    if isinstance(data, dict) and data.get("error"):
        detail = data["error"]
        if isinstance(detail, dict):
            detail = detail.get("message") or json.dumps(detail, ensure_ascii=False)
        raise RuntimeError(f"OpenRouter 오류: {detail}")


def _extract_search(data) -> tuple:
    """(citations, content, searches) 를 뽑는다. citations가 비면 검색이 수행되지 않은 것."""
    choice = (data.get("choices") or [{}])[0] if isinstance(data, dict) else {}
    message = choice.get("message") or {}
    citations = [
        ann.get("url_citation") or {}
        for ann in (message.get("annotations") or [])
        if isinstance(ann, dict) and ann.get("url_citation")
    ]
    content = message.get("content")
    if content and not isinstance(content, str):
        content = json.dumps(content, ensure_ascii=False)
    usage = (data.get("usage") or {}) if isinstance(data, dict) else {}
    searches = (usage.get("server_tool_use") or {}).get("web_search_requests")
    return citations, (content or ""), searches


def _render(citations: list, content: str) -> str:
    parts = []
    if citations:
        sources = "\n".join(
            f"[{index}] {item.get('title') or '(제목 없음)'}\n    {item.get('url') or ''}"
            for index, item in enumerate(citations, 1)
        )
        parts.append(f"출처 {len(citations)}건:\n{sources}")
    if content.strip():
        parts.append(_clip(content, MAX_CONTENT_CHARS))
    return "\n\n".join(parts)


def _server_tool_parameters(options: dict, max_results: int) -> dict:
    params = {"max_results": max_results}
    if options.get("engine"):
        params["engine"] = options["engine"]
    if options.get("max_uses"):
        params["max_uses"] = options["max_uses"]
    if options.get("max_total_results"):
        params["max_total_results"] = options["max_total_results"]
    return params


def _search_openrouter(
    query: str, token: str, model: str, base_url: str, max_results: int, options: dict
) -> str:
    endpoint = f"{base_url}/chat/completions"

    # 1순위: openrouter:web_search 서버툴 (web 플러그인 대체 경로)
    data = _post_json(
        endpoint,
        {
            "model": model,
            "messages": [
                {"role": "system", "content": SEARCH_SYSTEM_PROMPT},
                {"role": "user", "content": query},
            ],
            "tools": [
                {
                    "type": "openrouter:web_search",
                    "parameters": _server_tool_parameters(options, max_results),
                }
            ],
        },
        token,
    )
    _raise_on_api_error(data)
    citations, content, searches = _extract_search(data)
    if citations:
        _log(f"server tool search ok (citations={len(citations)}, searches={searches})")
        return _render(citations, content) or "검색 결과가 없습니다."

    # 서버툴이 검색을 수행하지 않았다: 레거시 web 플러그인(항상 1회 검색)으로 폴백.
    # 플러그인이 제거된 뒤에는 이 블록이 조용히 건너뛰어진다.
    if options.get("plugin_fallback"):
        _log("server tool performed no search; trying deprecated web plugin fallback")
        try:
            legacy = _post_json(
                endpoint,
                {
                    "model": model,
                    "plugins": [{"id": "web", "max_results": max_results}],
                    "messages": [{"role": "user", "content": query}],
                },
                token,
            )
            _raise_on_api_error(legacy)
            legacy_citations, legacy_content, _ = _extract_search(legacy)
            if legacy_citations or legacy_content.strip():
                _log(f"plugin fallback ok (citations={len(legacy_citations)})")
                return _render(legacy_citations, legacy_content)
        except Exception as exc:  # 폴백 실패는 치명적이지 않다
            _log(f"plugin fallback failed: {exc}")

    return _render(citations, content) or "검색 결과가 없습니다."


def _fetch(url: str) -> str:
    text = _get_text(url)
    if not text.strip():
        return "빈 응답입니다."
    if re.search(r"<html|<body|<div|<p\b", text, re.I):
        return _html_to_text(text)
    return _clip(text, MAX_CONTENT_CHARS)


def _html_to_text(html_text: str) -> str:
    text = re.sub(r"(?is)<(script|style|noscript)\b.*?</\1\s*>", "", html_text)
    text = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)\s*>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    text = re.sub(r"[ \t\u00a0]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text)
    return _clip(text.strip(), MAX_CONTENT_CHARS)


if __name__ == "__main__":
    main()