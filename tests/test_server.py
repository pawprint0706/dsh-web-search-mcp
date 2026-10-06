#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dsh-web-search MCP 서버 테스트 (표준 라이브러리만 사용, Python 3.8+).

`server/dsh-web-search.py` 는 파일명에 하이픈이 있어 일반 `import` 가 불가능하므로
`importlib.util.spec_from_file_location` 으로 로드한다(로드 직후 `sys.modules` 등록).

테스트 원칙:
  1. 네트워크 호출 금지(OpenRouter 과금 방지).
     - `tools/call web_search` 는 실제 검색을 수행하지 않는다. stdio 프로브도
       `initialize` / `notifications/initialized` / `tools/list` 까지만 보낸다.
     - 네트워크를 타는 함수(`_post_json`, `_get_text`, `urllib.request.urlopen`)는
       테스트에서 mock 으로 대체하고, 호출되지 않았음을 명시적으로 검증한다.
  2. 실제 `~/.dsh` 를 읽거나 쓰지 않는다(`DSH_HOME` 을 매 테스트 임시 디렉터리로 지정).
  3. 관련 환경변수(`DSH_HOME`, `DSH_WEB_SEARCH_*`, `OPENROUTER_API_KEY`)는 매 테스트마다
     저장/제거 후 복원한다.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVER_PATH = REPO_ROOT / "server" / "dsh-web-search.py"
MODULE_NAME = "dsh_web_search_under_test"

# 테스트마다 명시적으로 설정/제거하는 환경변수 목록.
MANAGED_ENV = (
    "DSH_HOME",
    "DSH_WEB_SEARCH_API_KEY",
    "DSH_WEB_SEARCH_BASE_URL",
    "DSH_WEB_SEARCH_MODEL",
    "DSH_WEB_SEARCH_MAX_RESULTS",
    "DSH_WEB_SEARCH_ENGINE",
    "OPENROUTER_API_KEY",
)

TRUNCATION_SUFFIX = " ...(truncated)"


def _load_server_module():
    """하이픈이 포함된 파일명의 모듈을 importlib 로 로드한다."""
    if not SERVER_PATH.is_file():
        raise AssertionError("서버 스크립트를 찾을 수 없습니다: %s" % SERVER_PATH)
    spec = importlib.util.spec_from_file_location(MODULE_NAME, str(SERVER_PATH))
    if spec is None or spec.loader is None:
        raise AssertionError("모듈 스펙을 만들지 못했습니다: %s" % SERVER_PATH)
    module = importlib.util.module_from_spec(spec)
    # exec_module 이전에 등록해 두어야 모듈 내부에서 자기 참조/피클이 가능하다.
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


class IsolatedEnvTestCase(unittest.TestCase):
    """DSH_HOME 과 관련 환경변수를 임시 디렉터리로 격리하는 베이스 클래스."""

    def setUp(self):
        self._saved_env = {}
        for name in MANAGED_ENV:
            self._saved_env[name] = os.environ.pop(name, None)
        self._tmp = tempfile.TemporaryDirectory(prefix="dsh-web-search-test-")
        self.dsh_home = Path(self._tmp.name)
        os.environ["DSH_HOME"] = str(self.dsh_home)

    def tearDown(self):
        for name, value in self._saved_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        self._tmp.cleanup()

    # ------------------------------------------------------------ 헬퍼
    def write_credentials(self, body):
        path = self.dsh_home / ".credentials.yaml"
        path.write_text(body, encoding="utf-8")
        return path

    def write_user_config(self, payload):
        path = self.dsh_home / "web-search.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return path

    def write_default_credentials(self, value="sk-or-v1-abc"):
        return self.write_credentials(
            "version: 1\nrefs:\n  OPENROUTER_API_KEY: %s\n" % value
        )


# ---------------------------------------------------------------- 1. 자격증명
class CredentialsRefsTests(IsolatedEnvTestCase):
    def test_reads_names_from_refs_section(self):
        self.write_credentials(
            "version: 1\n"
            "refs:\n"
            "  OPENROUTER_API_KEY: sk-or-v1-abc\n"
            "  DEEPSEEK_API_KEY: 'sk-ds-123'\n"
            "  QUOTED: \"sk-q-456\"\n"
            "  EMPTY_KEY:\n"
            "  # 주석 줄은 무시된다\n"
        )
        refs = server._credentials_refs()
        self.assertEqual(refs.get("OPENROUTER_API_KEY"), "sk-or-v1-abc")
        self.assertEqual(refs.get("DEEPSEEK_API_KEY"), "sk-ds-123")
        self.assertEqual(refs.get("QUOTED"), "sk-q-456")
        # 값이 비어 있는 키와 주석은 담기지 않는다.
        self.assertNotIn("EMPTY_KEY", refs)
        # refs 밖(최상위) 키는 담기지 않는다.
        self.assertNotIn("version", refs)

    def test_ignores_keys_outside_refs_section(self):
        self.write_credentials(
            "version: 1\n"
            "OPENROUTER_API_KEY: outside-value\n"
            "refs:\n"
            "  OPENROUTER_API_KEY: inside-value\n"
            "other_section:\n"
            "  AFTER_REFS: ignored-value\n"
        )
        refs = server._credentials_refs()
        # refs 안쪽 값이 이긴다(바깥 섹션 값이 덮어쓰지 않는다).
        self.assertEqual(refs.get("OPENROUTER_API_KEY"), "inside-value")
        self.assertNotIn("AFTER_REFS", refs)

    def test_missing_file_returns_empty_dict(self):
        self.assertFalse((self.dsh_home / ".credentials.yaml").exists())
        self.assertEqual(server._credentials_refs(), {})

    def test_handles_utf8_bom(self):
        self.write_credentials(
            "\ufeffversion: 1\nrefs:\n  OPENROUTER_API_KEY: sk-or-v1-bom\n"
        )
        self.assertEqual(
            server._credentials_refs().get("OPENROUTER_API_KEY"), "sk-or-v1-bom"
        )

    def test_reads_from_dsh_home_override(self):
        self.write_default_credentials("sk-or-v1-home")
        self.assertEqual(str(server._dsh_home()), str(self.dsh_home))
        self.assertEqual(
            server._credentials_refs().get("OPENROUTER_API_KEY"), "sk-or-v1-home"
        )


# ---------------------------------------------------------------- 2. 설정 해석
class ResolveConfigTests(IsolatedEnvTestCase):
    def test_rejects_non_openrouter_base_url(self):
        os.environ["DSH_WEB_SEARCH_API_KEY"] = "sk-or-v1-env"
        os.environ["DSH_WEB_SEARCH_BASE_URL"] = "https://api.example.com/v1"
        token, model, base_url, options, error = server.resolve_config()
        self.assertTrue(error)
        self.assertIn("OpenRouter 전용", error)
        self.assertIn("api.example.com", error)
        self.assertEqual((token, model, base_url), ("", "", ""))
        self.assertIsInstance(options, dict)

    def test_accepts_openrouter_base_url_and_strips_trailing_slash(self):
        os.environ["DSH_WEB_SEARCH_API_KEY"] = "sk-or-v1-env"
        os.environ["DSH_WEB_SEARCH_BASE_URL"] = "https://openrouter.ai/api/v1/"
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(token, "sk-or-v1-env")
        self.assertEqual(base_url, "https://openrouter.ai/api/v1")

    def test_rejects_lookalike_host(self):
        """접두 일치가 아니라 호스트를 정확히 비교해야 한다.

        `https://openrouter.ai.evil.example/v1` 같은 유사 호스트를 통과시키면
        Bearer 토큰이 제3자에게 전송된다.
        """
        for bad in (
            "https://openrouter.ai.evil.example/v1",
            "https://openrouter.ai@evil.example/v1",
            "https://openrouter.ai:8443/v1",
            "https://openrouter.ai:abc/v1",
            "http://openrouter.ai/api/v1",
            "https://openrouter.ai./api/v1",
            "https://openrouter.ai",
        ):
            with self.subTest(base_url=bad):
                os.environ["DSH_WEB_SEARCH_API_KEY"] = "sk-or-v1-env"
                os.environ["DSH_WEB_SEARCH_BASE_URL"] = bad
                token, model, base_url, options, error = server.resolve_config()
                if bad == "https://openrouter.ai":
                    self.assertEqual(error, "")
                    self.assertEqual(base_url, bad)
                else:
                    self.assertTrue(error, f"{bad} 는 거부되어야 합니다")
                    self.assertEqual((token, model, base_url), ("", "", ""))

    def test_accepts_openrouter_host_with_explicit_443(self):
        os.environ["DSH_WEB_SEARCH_API_KEY"] = "sk-or-v1-env"
        os.environ["DSH_WEB_SEARCH_BASE_URL"] = "https://openrouter.ai:443/api/v1"
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(token, "sk-or-v1-env")
        self.assertEqual(base_url, "https://openrouter.ai:443/api/v1")

    def test_missing_token_reports_korean_error(self):
        token, model, base_url, options, error = server.resolve_config()
        self.assertTrue(error)
        self.assertIn("OpenRouter 토큰을 찾지 못했습니다", error)
        self.assertEqual((token, model, base_url), ("", "", ""))

    def test_placeholder_token_is_treated_as_missing(self):
        self.write_user_config({"api_key": "YOUR-API-KEY-HERE"})
        token, model, base_url, options, error = server.resolve_config()
        self.assertIn("OpenRouter 토큰을 찾지 못했습니다", error)
        self.assertEqual(token, "")

    def test_token_precedence(self):
        # 1) .credentials.yaml 의 refs 값
        self.write_default_credentials("sk-or-v1-cred")
        self.assertEqual(server.resolve_config()[0], "sk-or-v1-cred")
        # 2) web-search.json api_key 가 credentials 를 이긴다
        self.write_user_config({"api_key": "sk-or-v1-cfg"})
        self.assertEqual(server.resolve_config()[0], "sk-or-v1-cfg")
        # 3) OPENROUTER_API_KEY 환경변수가 설정 파일을 이긴다
        os.environ["OPENROUTER_API_KEY"] = "sk-or-v1-generic-env"
        self.assertEqual(server.resolve_config()[0], "sk-or-v1-generic-env")
        # 4) DSH_WEB_SEARCH_API_KEY 가 최우선
        os.environ["DSH_WEB_SEARCH_API_KEY"] = "sk-or-v1-dsh-env"
        self.assertEqual(server.resolve_config()[0], "sk-or-v1-dsh-env")

    def test_defaults_when_no_user_config(self):
        self.write_default_credentials()
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(token, "sk-or-v1-abc")
        self.assertEqual(model, server.DEFAULT_SEARCH_MODEL)
        self.assertEqual(base_url, server.DEFAULT_BASE_URL)
        self.assertEqual(options["max_results"], server.DEFAULT_MAX_RESULTS)
        self.assertEqual(options["engine"], server.DEFAULT_SEARCH_ENGINE)
        self.assertIs(options["plugin_fallback"], True)
        self.assertEqual(options["max_uses"], 0)
        self.assertEqual(options["max_total_results"], 0)

    def test_user_config_values(self):
        self.write_default_credentials()
        self.write_user_config(
            {
                "model": "vendor/model-x",
                "engine": "native",
                "max_results": 8,
                "max_uses": 4,
                "max_total_results": 20,
                "plugin_fallback": False,
            }
        )
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(model, "vendor/model-x")
        self.assertEqual(base_url, server.DEFAULT_BASE_URL)
        self.assertEqual(options["max_results"], 8)
        self.assertEqual(options["engine"], "native")
        self.assertEqual(options["max_uses"], 4)
        self.assertEqual(options["max_total_results"], 20)
        self.assertIs(options["plugin_fallback"], False)

    def test_environment_overrides_user_config(self):
        self.write_default_credentials()
        self.write_user_config(
            {
                "model": "cfg/model",
                "engine": "cfg-engine",
                "max_results": 2,
                "base_url": "https://openrouter.ai/api/v1/",
            }
        )
        os.environ["DSH_WEB_SEARCH_MODEL"] = "env/model"
        os.environ["DSH_WEB_SEARCH_ENGINE"] = "env-engine"
        os.environ["DSH_WEB_SEARCH_MAX_RESULTS"] = "9"
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(model, "env/model")
        self.assertEqual(base_url, "https://openrouter.ai/api/v1")
        self.assertEqual(options["max_results"], 9)
        self.assertEqual(options["engine"], "env-engine")

    def test_max_results_is_clamped_to_1_10(self):
        self.write_default_credentials()
        # (설정값, 기대값) - 비정상값(0, 음수, 문자열)은 기본값으로 되돌아간다.
        cases = (
            (99, 10),
            (11, 10),
            (10, 10),
            (1, 1),
            ("7", 7),
            ("abc", server.DEFAULT_MAX_RESULTS),
            (-4, server.DEFAULT_MAX_RESULTS),
            (0, server.DEFAULT_MAX_RESULTS),
        )
        for raw, expected in cases:
            with self.subTest(max_results=raw):
                self.write_user_config({"max_results": raw})
                _, _, _, options, error = server.resolve_config()
                self.assertEqual(error, "")
                self.assertEqual(options["max_results"], expected)
                self.assertGreaterEqual(options["max_results"], 1)
                self.assertLessEqual(options["max_results"], 10)

    def test_invalid_user_config_json_is_ignored(self):
        self.write_default_credentials()
        (self.dsh_home / "web-search.json").write_text("{ not json", encoding="utf-8")
        token, model, base_url, options, error = server.resolve_config()
        self.assertEqual(error, "")
        self.assertEqual(token, "sk-or-v1-abc")
        self.assertEqual(model, server.DEFAULT_SEARCH_MODEL)
        self.assertEqual(options["max_results"], server.DEFAULT_MAX_RESULTS)

    def test_non_dict_user_config_is_ignored(self):
        self.write_default_credentials()
        (self.dsh_home / "web-search.json").write_text("[1, 2, 3]", encoding="utf-8")
        self.assertEqual(server._user_config(), {})
        self.assertEqual(server.resolve_config()[4], "")


# ---------------------------------------------------------------- 3. HTML → 텍스트
class HtmlToTextTests(unittest.TestCase):
    def test_removes_script_style_and_noscript(self):
        raw = (
            "<html><head>"
            '<style>.x { color: red; }</style>'
            '<script type="text/javascript" src="//example.com/a.js"></script>'
            "<noscript>JS 를 켜세요</noscript>"
            "</head><body><p>본문입니다</p></body></html>"
        )
        out = server._html_to_text(raw)
        self.assertIn("본문입니다", out)
        self.assertNotIn("color: red", out)
        self.assertNotIn("example.com/a.js", out)
        self.assertNotIn("JS 를 켜세요", out)
        self.assertNotIn("<", out)

    def test_block_tags_become_newlines(self):
        self.assertEqual(server._html_to_text("<p>one</p><p>two</p>"), "one\ntwo")
        self.assertEqual(server._html_to_text("<div>a</div><div>b</div>"), "a\nb")
        self.assertEqual(server._html_to_text("<ul><li>a</li><li>b</li></ul>"), "a\nb")
        self.assertEqual(server._html_to_text("a<br>b"), "a\nb")
        self.assertEqual(server._html_to_text("a<br/>b"), "a\nb")

    def test_unescapes_html_entities(self):
        out = server._html_to_text("<p>AT&amp;T &lt;tag&gt; &#39;q&#39; &nbsp;end</p>")
        self.assertEqual(out, "AT&T <tag> 'q' end")

    def test_collapses_whitespace_and_blank_lines(self):
        out = server._html_to_text("<div>a   b\t\tc</div>\n\n\n<div>d</div>")
        self.assertEqual(out, "a b c\n\nd")

    def test_strips_inline_tags_but_keeps_text(self):
        self.assertEqual(
            server._html_to_text('<a href="https://example.com">링크</a>'),
            "링크",
        )

    def test_truncates_to_max_content_chars(self):
        raw = "<p>" + ("word " * 10000) + "</p>"
        out = server._html_to_text(raw)
        self.assertTrue(out.endswith(TRUNCATION_SUFFIX))
        self.assertEqual(
            len(out), server.MAX_CONTENT_CHARS + len(TRUNCATION_SUFFIX)
        )

    def test_plain_text_is_returned_unchanged(self):
        out = server._html_to_text("태그 없는 텍스트")
        self.assertEqual(out, "태그 없는 텍스트")


# ---------------------------------------------------------------- 4. _clip
class ClipTests(unittest.TestCase):
    def test_short_text_is_returned_as_is(self):
        self.assertEqual(server._clip("abc", 10), "abc")
        self.assertEqual(server._clip("abc", 3), "abc")

    def test_surrounding_whitespace_is_stripped(self):
        self.assertEqual(server._clip("   abc  \n", 10), "abc")

    def test_long_text_gets_truncation_suffix(self):
        self.assertEqual(server._clip("abcdef", 3), "abc" + TRUNCATION_SUFFIX)

    def test_none_and_empty_are_treated_as_empty_string(self):
        self.assertEqual(server._clip(None, 5), "")
        self.assertEqual(server._clip("", 5), "")


# ---------------------------------------------------------------- 5. 응답 파싱
class ExtractSearchTests(unittest.TestCase):
    def _fake_response(self, content="요약 본문"):
        return {
            "choices": [
                {
                    "message": {
                        "content": content,
                        "annotations": [
                            {
                                "type": "url_citation",
                                "url_citation": {
                                    "url": "https://a.example/1",
                                    "title": "출처 A",
                                },
                            },
                            {"type": "other_annotation"},
                            {
                                "type": "url_citation",
                                "url_citation": {
                                    "url": "https://b.example/2",
                                    "title": "출처 B",
                                },
                            },
                            "문자열 주석은 무시",
                        ],
                    }
                }
            ],
            "usage": {"server_tool_use": {"web_search_requests": 2}},
        }

    def test_extracts_citations_content_and_searches(self):
        citations, content, searches = server._extract_search(self._fake_response())
        self.assertEqual(len(citations), 2)
        self.assertEqual(citations[0]["url"], "https://a.example/1")
        self.assertEqual(citations[0]["title"], "출처 A")
        self.assertEqual(citations[1]["url"], "https://b.example/2")
        self.assertEqual(content, "요약 본문")
        self.assertEqual(searches, 2)

    def test_empty_url_citation_is_dropped(self):
        data = {
            "choices": [
                {"message": {"content": "x", "annotations": [{"url_citation": {}}]}}
            ]
        }
        citations, content, searches = server._extract_search(data)
        self.assertEqual(citations, [])
        self.assertEqual(content, "x")
        self.assertIsNone(searches)

    def test_non_string_content_is_json_serialized(self):
        payload = [{"type": "text", "text": "조각"}]
        citations, content, searches = server._extract_search(
            self._fake_response(content=payload)
        )
        self.assertIsInstance(content, str)
        self.assertEqual(json.loads(content), payload)
        self.assertEqual(content, json.dumps(payload, ensure_ascii=False))

    def test_missing_fields_are_safe(self):
        self.assertEqual(server._extract_search({}), ([], "", None))
        self.assertEqual(
            server._extract_search({"choices": []}),
            ([], "", None),
        )
        self.assertEqual(
            server._extract_search({"choices": [{"message": None}]}),
            ([], "", None),
        )


# ---------------------------------------------------------------- 6. 렌더링
class RenderTests(unittest.TestCase):
    def test_renders_citations_then_body(self):
        citations = [
            {"url": "https://a.example", "title": "출처 A"},
            {"url": "https://b.example"},
        ]
        out = server._render(citations, "본문 텍스트")
        self.assertEqual(
            out,
            "출처 2건:\n"
            "[1] 출처 A\n"
            "    https://a.example\n"
            "[2] (제목 없음)\n"
            "    https://b.example\n"
            "\n"
            "본문 텍스트",
        )

    def test_empty_inputs_render_empty_string(self):
        self.assertEqual(server._render([], ""), "")
        self.assertEqual(server._render([], "   \n  "), "")

    def test_content_only_renders_content(self):
        self.assertEqual(server._render([], "본문만"), "본문만")

    def test_long_content_is_clipped(self):
        out = server._render([], "x" * (server.MAX_CONTENT_CHARS + 50))
        self.assertTrue(out.endswith(TRUNCATION_SUFFIX))
        self.assertEqual(
            len(out), server.MAX_CONTENT_CHARS + len(TRUNCATION_SUFFIX)
        )


# ---------------------------------------------------------------- 7. JSON-RPC
class HandleMessageTests(IsolatedEnvTestCase):
    def handle(self, msg, state=None):
        return server.handle_message(msg, {} if state is None else state)

    def request(self, method, msg_id=1, params=None):
        msg = {"jsonrpc": "2.0", "id": msg_id, "method": method}
        if params is not None:
            msg["params"] = params
        return msg

    def test_initialize_echoes_known_protocol_version(self):
        for version in sorted(server.KNOWN_PROTOCOL_VERSIONS):
            with self.subTest(protocolVersion=version):
                response = self.handle(
                    self.request("initialize", params={"protocolVersion": version})
                )
                result = response["result"]
                self.assertEqual(result["protocolVersion"], version)
                self.assertEqual(result["serverInfo"]["name"], server.SERVER_NAME)
                self.assertEqual(
                    result["serverInfo"]["version"], server.SERVER_VERSION
                )
                self.assertIn("tools", result["capabilities"])

    def test_initialize_falls_back_to_latest_for_unknown_version(self):
        for version in ("2025-11-25", "1999-01-01", ""):
            with self.subTest(protocolVersion=version):
                response = self.handle(
                    self.request("initialize", params={"protocolVersion": version})
                )
                self.assertEqual(
                    response["result"]["protocolVersion"],
                    server.LATEST_PROTOCOL_VERSION,
                )
                self.assertIn(
                    response["result"]["protocolVersion"],
                    server.KNOWN_PROTOCOL_VERSIONS,
                )

    def test_initialize_without_params_uses_latest(self):
        response = self.handle(self.request("initialize"))
        self.assertEqual(
            response["result"]["protocolVersion"], server.LATEST_PROTOCOL_VERSION
        )
        self.assertEqual(response["id"], 1)

    def test_notifications_return_none(self):
        for method in ("notifications/initialized", "notifications/cancelled"):
            with self.subTest(method=method):
                self.assertIsNone(self.handle({"jsonrpc": "2.0", "method": method}))

    def test_request_without_id_returns_none(self):
        self.assertIsNone(self.handle({"jsonrpc": "2.0", "method": "tools/list"}))

    def test_tools_list_contains_both_tools(self):
        response = self.handle(self.request("tools/list", msg_id=7))
        self.assertEqual(response["id"], 7)
        tools = response["result"]["tools"]
        names = [tool["name"] for tool in tools]
        self.assertIn("web_search", names)
        self.assertIn("web_fetch", names)
        by_name = {tool["name"]: tool for tool in tools}
        for name in ("web_search", "web_fetch"):
            self.assertEqual(by_name[name]["inputSchema"]["type"], "object")
            self.assertIs(by_name[name]["inputSchema"]["additionalProperties"], False)
        self.assertEqual(by_name["web_search"]["inputSchema"]["required"], ["query"])
        self.assertEqual(by_name["web_fetch"]["inputSchema"]["required"], ["url"])

    def test_unknown_method_returns_method_not_found(self):
        response = self.handle(self.request("does/not/exist", msg_id=3))
        self.assertEqual(response["id"], 3)
        self.assertEqual(response["error"]["code"], -32601)
        self.assertIn("does/not/exist", response["error"]["message"])

    def test_invalid_message_returns_invalid_request(self):
        response = server.handle_message("문자열", {})
        self.assertEqual(response["error"]["code"], -32600)
        self.assertIsNone(response["id"])

    def test_ping_and_empty_listings(self):
        self.assertEqual(self.handle(self.request("ping"))["result"], {})
        self.assertEqual(
            self.handle(self.request("resources/list"))["result"]["resources"], []
        )
        self.assertEqual(
            self.handle(self.request("prompts/list"))["result"]["prompts"], []
        )

    def test_unknown_tool_call_is_error_result(self):
        response = self.handle(
            self.request(
                "tools/call",
                params={"name": "no_such_tool", "arguments": {}},
            )
        )
        result = response["result"]
        self.assertIs(result["isError"], True)
        self.assertIn("no_such_tool", result["content"][0]["text"])

    def test_tool_argument_validation_errors_are_results_not_crashes(self):
        cases = (
            ("web_search", {}),
            ("web_search", {"query": "   "}),
            ("web_fetch", {}),
            ("web_fetch", {"url": "ftp://example.com/file"}),
        )
        for name, arguments in cases:
            with self.subTest(tool=name, arguments=arguments):
                response = self.handle(
                    self.request(
                        "tools/call", params={"name": name, "arguments": arguments}
                    )
                )
                self.assertIn("result", response)
                self.assertIs(response["result"]["isError"], True)
                self.assertTrue(response["result"]["content"][0]["text"])

    def test_argument_errors_do_not_touch_network(self):
        """인자 검증 실패 경로는 네트워크를 타지 않아야 한다(과금 방지)."""
        with mock.patch.object(server, "_post_json") as post_json, mock.patch.object(
            server, "_get_text"
        ) as get_text, mock.patch.object(
            server.urllib.request, "urlopen"
        ) as urlopen:
            self.handle(
                self.request(
                    "tools/call",
                    params={"name": "web_search", "arguments": {"query": ""}},
                )
            )
            self.handle(
                self.request(
                    "tools/call",
                    params={"name": "web_fetch", "arguments": {"url": "ftp://x/y"}},
                )
            )
            post_json.assert_not_called()
            get_text.assert_not_called()
            urlopen.assert_not_called()

    def test_tools_call_success_path_with_mocked_backend(self):
        """백엔드를 mock 으로 대체해 tools/call 성공 응답 형태만 검증한다."""
        self.write_default_credentials()
        with mock.patch.object(
            server, "_search_openrouter", return_value="스텁 검색 결과"
        ) as search:
            response = self.handle(
                self.request(
                    "tools/call",
                    params={
                        "name": "web_search",
                        "arguments": {"query": "테스트 질의", "max_results": 3},
                    },
                )
            )
        self.assertEqual(search.call_count, 1)
        self.assertIs(response["result"]["isError"], False)
        self.assertEqual(response["result"]["content"][0]["type"], "text")
        self.assertEqual(response["result"]["content"][0]["text"], "스텁 검색 결과")
        # max_results 인자가 백엔드로 전달된다.
        self.assertEqual(search.call_args[0][4], 3)

    def test_tools_call_reports_backend_failure_as_error_result(self):
        self.write_default_credentials()
        with mock.patch.object(
            server, "_search_openrouter", side_effect=RuntimeError("백엔드 실패")
        ):
            response = self.handle(
                self.request(
                    "tools/call",
                    params={"name": "web_search", "arguments": {"query": "질의"}},
                )
            )
        self.assertIs(response["result"]["isError"], True)
        self.assertIn("백엔드 실패", response["result"]["content"][0]["text"])

    def test_tools_call_without_arguments_dict(self):
        with mock.patch.object(server, "_post_json") as post_json:
            response = self.handle(self.request("tools/call", params={"name": "web_search"}))
            post_json.assert_not_called()
        self.assertIs(response["result"]["isError"], True)

    def test_search_without_token_is_error_result_without_network(self):
        with mock.patch.object(server, "_post_json") as post_json:
            response = self.handle(
                self.request(
                    "tools/call",
                    params={"name": "web_search", "arguments": {"query": "질의"}},
                )
            )
            post_json.assert_not_called()
        text = response["result"]["content"][0]["text"]
        self.assertIs(response["result"]["isError"], True)
        self.assertIn("OpenRouter 토큰을 찾지 못했습니다", text)


# ---------------------------------------------------------------- 8. 인코딩 가드
class PowerShellEncodingTests(unittest.TestCase):
    """PowerShell 스크립트가 UTF-8(BOM 포함)인지 확인한다.

    BOM 이 없으면 Windows PowerShell 5.1 이 파일을 CP949 로 오해석해 한글이 깨지고
    구문 오류가 발생한다(README 3절 요구사항). 저장소 루트의 *.ps1 과 tests/*.ps1
    (이 검사를 수행하는 run-tests.ps1 자신 포함)을 대상으로 한다.
    """

    UTF8_BOM = b"\xef\xbb\xbf"

    def ps1_targets(self):
        targets = []
        for name in ("install.ps1", "verify.ps1", "uninstall.ps1"):
            path = REPO_ROOT / name
            if path.is_file():
                targets.append(path)
        targets.extend(sorted((REPO_ROOT / "tests").glob("*.ps1")))
        return targets

    def test_ps1_files_have_utf8_bom(self):
        targets = self.ps1_targets()
        if not targets:
            self.skipTest("검사할 .ps1 파일이 없습니다: %s" % REPO_ROOT)
        missing = [
            str(path.relative_to(REPO_ROOT))
            for path in targets
            if path.read_bytes()[:3] != self.UTF8_BOM
        ]
        self.assertEqual(
            missing,
            [],
            "UTF-8 BOM 이 없는 PowerShell 스크립트가 있습니다(한글이 CP949 로 "
            "오해석됩니다): %s" % ", ".join(missing),
        )


# ---------------------------------------------------------------- 9. stdio 스모크
class StdioSmokeTests(unittest.TestCase):
    TIMEOUT_SECONDS = 30

    def test_handshake_and_tools_list_over_stdio(self):
        with tempfile.TemporaryDirectory(prefix="dsh-web-search-stdio-") as tmp:
            env = dict(os.environ)
            for name in MANAGED_ENV:
                env.pop(name, None)
            # 실제 ~/.dsh 대신 임시 DSH_HOME 을 쓰게 한다.
            env["DSH_HOME"] = tmp
            env["PYTHONIOENCODING"] = "utf-8"
            env["PYTHONUTF8"] = "1"

            requests = [
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        # DSH MCP 클라이언트가 보내는 값(서버 KNOWN 목록 밖 → LATEST 로 응답).
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": "dsh-unittest", "version": "1.0"},
                    },
                },
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            ]
            payload = "".join(
                json.dumps(item, ensure_ascii=False) + "\n" for item in requests
            )

            proc = subprocess.Popen(
                [sys.executable, str(SERVER_PATH)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                cwd=str(REPO_ROOT),
            )
            try:
                try:
                    stdout, stderr = proc.communicate(
                        payload, timeout=self.TIMEOUT_SECONDS
                    )
                    timed_out = False
                except subprocess.TimeoutExpired:
                    timed_out = True
                    proc.kill()
                    stdout, stderr = proc.communicate()
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=10)

            self.assertFalse(
                timed_out,
                "stdio 프로브가 %d초 안에 끝나지 않아 프로세스를 종료했습니다. stderr=%r"
                % (self.TIMEOUT_SECONDS, stderr),
            )
            self.assertEqual(
                proc.returncode, 0, "stdio 서버가 비정상 종료했습니다: %r" % (stderr,)
            )

            lines = [line for line in stdout.splitlines() if line.strip()]
            responses = {}
            for line in lines:
                obj = json.loads(line)  # JSON 이 아니면 테스트 실패
                if isinstance(obj, dict) and obj.get("id") is not None:
                    responses[obj["id"]] = obj

            # notification 에 대한 응답은 없어야 한다(id 1, 2 두 건만).
            self.assertEqual(sorted(responses), [1, 2])
            self.assertEqual(len(lines), 2)

            init_result = responses[1]["result"]
            self.assertEqual(
                init_result["protocolVersion"], server.LATEST_PROTOCOL_VERSION
            )
            self.assertIn(
                init_result["protocolVersion"], server.KNOWN_PROTOCOL_VERSIONS
            )
            self.assertEqual(init_result["serverInfo"]["name"], server.SERVER_NAME)

            names = sorted(tool["name"] for tool in responses[2]["result"]["tools"])
            self.assertIn("web_search", names)
            self.assertIn("web_fetch", names)
            self.assertNotIn("error", responses[2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
