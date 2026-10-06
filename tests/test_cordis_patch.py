#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`tools/cordis_patch.py`(POSIX 설치 스크립트의 패치 편집기) 테스트.

install.sh / uninstall.sh 가 이 헬퍼로 cordis.patch.yml 과 AGENTS.md 를 편집하므로,
여기서 install.ps1 과 같은 동작(멱등, 중복 id 정리, 빈 `- insert:` 정리, 사용자 행
보존)이 유지되는지 고정한다. 표준 라이브러리만 사용한다.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER_PATH = REPO_ROOT / "tools" / "cordis_patch.py"
MODULE_NAME = "cordis_patch_under_test"

MANAGED_BLOCK = """# >>> dsh-web-search-mcp managed block (do not edit) >>>
# install.sh 이 생성/관리합니다.
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  disabled: true
- insert:
    - id: mcp-dsh-web-search
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: dsh-web-search
        transport: stdio
        command: '/Users/x/.dsh/dsh-runtimes/x/dependencies/python/bin/python3'
        args:
          - '/Users/x/.dsh/mcp/dsh-web-search.py'
        env:
          DSH_HOME: '/Users/x/.dsh'
        toolCallTimeoutMs: 180000
# <<< dsh-web-search-mcp managed block <<<
"""

USER_PATCH = """- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      openrouter:
        apiKeyEnv: OPENROUTER_API_KEY
- id: ui-theme
  name: "@deepseek-ai/dsh-client-ui-theme"
  config:
    fontSize: 18
"""

AGENTS_SECTION = """# DSH 전역 지침

## 웹 검색 도구 선택

- 웹 검색에는 `mcp__dsh-web-search__web_search` 를 쓴다.
"""


def _load_helper():
    if not HELPER_PATH.is_file():
        raise AssertionError("헬퍼를 찾을 수 없습니다: %s" % HELPER_PATH)
    spec = importlib.util.spec_from_file_location(MODULE_NAME, str(HELPER_PATH))
    if spec is None or spec.loader is None:
        raise AssertionError("모듈 스펙을 만들지 못했습니다: %s" % HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


helper = _load_helper()


class PatchTestBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.patch_path = self.root / "cordis.patch.yml"
        self.block_path = self.root / "block.yml"
        self.block_path.write_text(MANAGED_BLOCK, encoding="utf-8")

    def write_patch(self, text: str, newline: str = "\n"):
        # newline="" 로 직접 써야 Windows 에서 "\n" 이 다시 번역되지 않는다.
        with open(self.patch_path, "w", encoding="utf-8", newline="") as stream:
            stream.write(text.replace("\n", newline))

    def read_patch(self) -> str:
        return self.patch_path.read_text(encoding="utf-8")


class PatchInstallTests(PatchTestBase):
    def test_appends_block_and_preserves_user_rows(self):
        self.write_patch(USER_PATCH)
        self.assertEqual(helper.patch_install(self.patch_path, self.block_path), 0)
        text = self.read_patch()
        self.assertIn('- id: llm-pi-ai', text)
        self.assertIn('- id: ui-theme', text)
        self.assertIn(helper.PATCH_BEGIN, text)
        self.assertIn("toolCallTimeoutMs: 180000", text)
        # 사용자 행이 관리 블록보다 앞에 있어야 한다.
        self.assertLess(text.index('- id: llm-pi-ai'), text.index(helper.PATCH_BEGIN))
        # 블록은 파일 끝에 온다.
        self.assertTrue(text.rstrip().endswith(helper.PATCH_END))
        self.assertTrue(text.endswith("\n"))

    def test_is_idempotent(self):
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)
        first = self.read_patch()
        helper.patch_install(self.patch_path, self.block_path)
        self.assertEqual(first, self.read_patch())

    def test_replaces_existing_block(self):
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)
        old_block = "# >>> dsh-web-search-mcp managed block (do not edit) >>>\n- id: web-search-deepseek\n# <<< dsh-web-search-mcp managed block <<<\n"
        self.write_patch(USER_PATCH + "\n" + old_block)
        helper.patch_install(self.patch_path, self.block_path)
        text = self.read_patch()
        self.assertEqual(text.count(helper.PATCH_BEGIN), 1)
        self.assertEqual(text.count("- id: web-search-deepseek"), 1)

    def test_removes_hand_written_duplicate_rows(self):
        """손으로 넣은 동일 id 행은 중복 등록을 막기 위해 제거된다(install.ps1 과 동일)."""
        hand_written = (
            USER_PATCH
            + '\n- id: web-search-deepseek\n  name: "@deepseek-ai/dsh-web-search-deepseek"\n  disabled: true\n'
            + "- id: mcp-dsh-web-search\n  name: \"@deepseek-ai/dsh-mcp-client\"\n"
            + "  config:\n    serverName: dsh-web-search\n"
            + "- insert:\n"
        )
        self.write_patch(hand_written)
        helper.patch_install(self.patch_path, self.block_path)
        text = self.read_patch()
        self.assertEqual(text.count("- id: web-search-deepseek"), 1)
        self.assertEqual(text.count("- id: mcp-dsh-web-search"), 1)
        # 자식 없는 빈 `- insert:` 껍데기는 남지 않는다.
        self.assertEqual(text.count("- insert:"), 1)
        self.assertIn('- id: llm-pi-ai', text)

    def test_creates_missing_file(self):
        self.assertFalse(self.patch_path.exists())
        self.assertEqual(helper.patch_install(self.patch_path, self.block_path), 0)
        text = self.read_patch()
        self.assertTrue(text.startswith(helper.PATCH_BEGIN))
        self.assertTrue(text.rstrip().endswith(helper.PATCH_END))

    def test_preserves_crlf_newlines(self):
        self.write_patch(USER_PATCH, newline="\r\n")
        helper.patch_install(self.patch_path, self.block_path)
        raw = self.patch_path.read_bytes().decode("utf-8")
        self.assertIn("\r\n", raw)
        # CRLF 만 쓰고 LF 단독은 남기지 않는다.
        self.assertNotIn("\n", raw.replace("\r\n", ""))

    def test_block_without_trailing_newline(self):
        self.block_path.write_text(MANAGED_BLOCK.rstrip("\n"), encoding="utf-8")
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)
        self.assertTrue(self.read_patch().endswith(helper.PATCH_END + "\n"))


class PatchRemoveTests(PatchTestBase):
    def test_removes_block_and_keeps_user_rows(self):
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)
        self.assertEqual(helper.patch_remove(self.patch_path), 0)
        text = self.read_patch()
        self.assertNotIn(helper.PATCH_BEGIN, text)
        self.assertNotIn("mcp-dsh-web-search", text)
        self.assertNotIn("web-search-deepseek", text)
        self.assertIn('- id: llm-pi-ai', text)
        self.assertIn('- id: ui-theme', text)

    def test_is_idempotent(self):
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)
        helper.patch_remove(self.patch_path)
        first = self.read_patch()
        helper.patch_remove(self.patch_path)
        self.assertEqual(first, self.read_patch())

    def test_removes_hand_written_rows_outside_block(self):
        self.write_patch(
            USER_PATCH
            + '- id: mcp-dsh-web-search\n  name: "@deepseek-ai/dsh-mcp-client"\n'
            + "- insert:\n"
        )
        helper.patch_remove(self.patch_path)
        text = self.read_patch()
        self.assertNotIn("mcp-dsh-web-search", text)
        self.assertNotIn("- insert:", text)
        self.assertIn('- id: llm-pi-ai', text)

    def test_missing_file_is_not_created(self):
        self.assertEqual(helper.patch_remove(self.patch_path), 0)
        self.assertFalse(self.patch_path.exists())

    def test_removing_everything_leaves_an_empty_file(self):
        self.write_patch("")
        helper.patch_install(self.patch_path, self.block_path)
        helper.patch_remove(self.patch_path)
        self.assertEqual(self.read_patch(), "")


class PatchGetTests(PatchTestBase):
    def setUp(self):
        super().setUp()
        self.write_patch(USER_PATCH)
        helper.patch_install(self.patch_path, self.block_path)

    def _get(self, field):
        import io
        import contextlib
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = helper.patch_get(self.patch_path, field)
        return status, buffer.getvalue().strip()

    def test_reads_command_script_and_home(self):
        status, command = self._get("command")
        self.assertEqual(status, 0)
        self.assertEqual(command, "/Users/x/.dsh/dsh-runtimes/x/dependencies/python/bin/python3")
        status, script = self._get("script")
        self.assertEqual(status, 0)
        self.assertEqual(script, "/Users/x/.dsh/mcp/dsh-web-search.py")
        status, home = self._get("dsh_home")
        self.assertEqual(status, 0)
        self.assertEqual(home, "/Users/x/.dsh")
        status, timeout = self._get("timeout")
        self.assertEqual(status, 0)
        self.assertEqual(timeout, "180000")

    def test_missing_field_returns_failure(self):
        self.write_patch(USER_PATCH)
        status, value = self._get("command")
        self.assertEqual(status, 1)
        self.assertEqual(value, "")

    def test_unknown_field_returns_usage_error(self):
        # unknown field 는 stderr 로 안내하고 2 를 돌려준다.
        import contextlib
        import io
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            status = helper.patch_get(self.patch_path, "nope")
        self.assertEqual(status, 2)


class AgentsSectionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.agents_path = self.root / "AGENTS.md"
        self.section_path = self.root / "section.md"
        self.section_path.write_text(AGENTS_SECTION, encoding="utf-8")

    def test_creates_file_with_markers(self):
        self.assertEqual(helper.agents_install(self.agents_path, self.section_path), 0)
        text = self.agents_path.read_text(encoding="utf-8")
        self.assertTrue(text.startswith(helper.AGENTS_BEGIN))
        self.assertTrue(text.rstrip().endswith(helper.AGENTS_END))
        self.assertIn("mcp__dsh-web-search__web_search", text)

    def test_preserves_existing_content_and_is_idempotent(self):
        self.agents_path.write_text("# 내 규칙\n\n- 항상 한국어로 답한다\n", encoding="utf-8")
        helper.agents_install(self.agents_path, self.section_path)
        first = self.agents_path.read_text(encoding="utf-8")
        self.assertIn("# 내 규칙", first)
        self.assertLess(first.index("# 내 규칙"), first.index(helper.AGENTS_BEGIN))
        helper.agents_install(self.agents_path, self.section_path)
        self.assertEqual(first, self.agents_path.read_text(encoding="utf-8"))

    def test_remove_deletes_file_when_nothing_left(self):
        helper.agents_install(self.agents_path, self.section_path)
        self.assertEqual(helper.agents_remove(self.agents_path), 0)
        self.assertFalse(self.agents_path.exists())

    def test_remove_keeps_other_content(self):
        self.agents_path.write_text("# 내 규칙\n\n- 항상 한국어로 답한다\n", encoding="utf-8")
        helper.agents_install(self.agents_path, self.section_path)
        helper.agents_remove(self.agents_path)
        text = self.agents_path.read_text(encoding="utf-8")
        self.assertIn("# 내 규칙", text)
        self.assertNotIn(helper.AGENTS_BEGIN, text)

    def test_remove_missing_file_is_noop(self):
        self.assertEqual(helper.agents_remove(self.agents_path), 0)
        self.assertFalse(self.agents_path.exists())


class ShellScriptEncodingTests(unittest.TestCase):
    """POSIX 셸 스크립트는 BOM 없이 LF 로 저장되어야 한다.

    BOM 이 있으면 shebang(`#!/usr/bin/env bash`)이 깨지고, CRLF 면 macOS 셸이
    인터프리터 경로 뒤의 `\\r` 을 이름의 일부로 보아 실행에 실패한다.
    """

    SCRIPTS = (
        "install.sh",
        "verify.sh",
        "uninstall.sh",
        "tools/posix-common.sh",
        "tests/posix-fixture-test.sh",
    )

    def test_no_bom_and_shebang_and_lf(self):
        for name in self.SCRIPTS:
            path = REPO_ROOT / name
            with self.subTest(script=name):
                self.assertTrue(path.is_file(), "%s 가 없습니다" % name)
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), "%s 에 UTF-8 BOM 이 있습니다" % name)
                self.assertTrue(data.startswith(b"#!"), "%s 가 shebang 으로 시작하지 않습니다" % name)
                self.assertNotIn(b"\r\n", data, "%s 에 CRLF 가 있습니다(LF 여야 합니다)" % name)
                self.assertTrue(data.endswith(b"\n"), "%s 가 개행으로 끝나지 않습니다" % name)


class MarkerParityTests(unittest.TestCase):
    """셸 라이브러리와 python 헬퍼의 마커가 어긋나지 않는지 확인한다."""

    def test_shell_library_markers_match_helper(self):
        common = (REPO_ROOT / "tools" / "posix-common.sh").read_text(encoding="utf-8")
        for marker in (
            helper.PATCH_BEGIN,
            helper.PATCH_END,
            helper.AGENTS_BEGIN,
            helper.AGENTS_END,
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, common)

    def test_powershell_scripts_use_the_same_markers(self):
        for name in ("install.ps1", "uninstall.ps1", "verify.ps1"):
            text = (REPO_ROOT / name).read_text(encoding="utf-8-sig")
            with self.subTest(script=name):
                self.assertIn(helper.PATCH_BEGIN, text)
                self.assertIn(helper.PATCH_END, text)


if __name__ == "__main__":
    unittest.main()
