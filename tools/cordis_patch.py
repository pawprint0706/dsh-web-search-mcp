#!/usr/bin/env python3
"""Cordis 프로필 패치 / AGENTS.md 관리 블록 편집기 (macOS·POSIX 설치 스크립트 공용).

`install.ps1` / `uninstall.ps1` 이 PowerShell 로 하는 줄 단위 편집을 POSIX 쪽에서
같은 동작으로 수행한다. 셸에서 직접 줄을 다루면 id 기반 리스트 제거(들여쓰기 인식)와
빈 `- insert:` 정리가 지저분해지므로, python(설치 요구사항)으로 옮겨 단위 테스트가
가능하게 했다.

동작 규칙 (install.ps1 과 동일해야 한다):

1. 마커 사이의 관리 블록을 제거한다.
2. 관리 대상 id(`mcp-dsh-web-search`, `web-search-deepseek`)를 가진 리스트 항목을
   들여쓰기 깊이와 무관하게 제거한다 → 중복 등록(`serverName already in use`) 방지.
3. 자식이 모두 제거되어 빈 껍데기만 남은 `- insert:` 항목을 제거한다
   (YAML 에서 null 이 되어 로더가 오류를 낼 수 있다).
4. 관리 블록/섹션을 끝에 다시 붙인다.

줄바꿈은 원본 파일 스타일(LF/CRLF)을 유지하고, 쓰기는 같은 디렉터리의 임시 파일을
거쳐 원자적으로 교체한다.

사용법:
    cordis_patch.py patch-install  <cordis.patch.yml> <managed-block-file>
    cordis_patch.py patch-remove   <cordis.patch.yml>
    cordis_patch.py agents-install <AGENTS.md> <section-file>
    cordis_patch.py agents-remove  <AGENTS.md>
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

PATCH_BEGIN = "# >>> dsh-web-search-mcp managed block (do not edit) >>>"
PATCH_END = "# <<< dsh-web-search-mcp managed block <<<"
AGENTS_BEGIN = "<!-- dsh-web-search-mcp:begin -->"
AGENTS_END = "<!-- dsh-web-search-mcp:end -->"

# 설치가 소유하는 패치 행 id. 이전에 손으로 넣은 동일 id 는 중복 등록을 막기 위해 제거한다.
MANAGED_ROW_IDS = ("mcp-dsh-web-search", "web-search-deepseek")


# ---------------------------------------------------------------- 줄 유틸


def read_lines(path: Path):
    """(lines, newline) 을 돌려준다. 파일이 없으면 ([], '\\n').

    줄 끝의 `\\r` 은 제거해 두고, 쓸 때 원래 스타일로 되돌린다.
    `read_text()` 를 쓰면 universal newlines 가 CRLF 를 LF 로 바꿔 스타일 감지가
    무력화되므로 newline="" 로 직접 읽는다.
    """
    if not path.exists():
        return [], "\n"
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        raw = stream.read()
    newline = "\r\n" if "\r\n" in raw else "\n"
    lines = [line.rstrip("\r") for line in raw.split("\n")]
    # 마지막 개행 뒤에 생기는 빈 조각은 제거한다(쓸 때 다시 붙인다).
    if lines and lines[-1] == "":
        lines.pop()
    return lines, newline


def write_lines(path: Path, lines, newline: str = "\n") -> None:
    """원자적으로 쓴다. 내용이 없으면 빈 파일을 만든다."""
    text = ""
    if lines:
        text = newline.join(lines) + newline
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".cordis-patch-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(tmp_name, str(path))
    except BaseException:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def remove_marked_block(lines, begin: str, end: str):
    """마커 사이(마커 포함)를 제거한다. 마커는 trim 후 비교한다."""
    out = []
    inside = False
    for line in lines:
        trimmed = line.strip()
        if trimmed == begin:
            inside = True
            continue
        if trimmed == end:
            inside = False
            continue
        if not inside:
            out.append(line)
    return out


def remove_list_item_by_id(lines, item_id: str):
    """`- id: <item_id>` 항목을 그 자식 줄들과 함께 제거한다(들여쓰기 깊이 무관)."""
    quoted = ("'%s'" % item_id, '"%s"' % item_id, item_id)
    out = []
    index = 0
    total = len(lines)
    while index < total:
        line = lines[index]
        stripped = line.strip()
        matched = False
        if stripped.startswith("- "):
            body = stripped[2:].strip()
            if body.startswith("id:"):
                value = body[3:].strip()
                matched = value in quoted
        if not matched:
            out.append(line)
            index += 1
            continue
        indent = _indent(line)
        index += 1  # id 줄 자체를 건너뛴다
        while index < total:
            child = lines[index]
            if child.strip() == "":
                index += 1
                continue
            child_indent = _indent(child)
            if child_indent < indent:
                break
            if child_indent == indent and child.lstrip().startswith("- "):
                break
            index += 1
    return out


def remove_empty_insert_lists(lines):
    """자식이 하나도 없는 `- insert:` 항목을 제거한다."""
    out = []
    index = 0
    total = len(lines)
    while index < total:
        line = lines[index]
        stripped = line.strip()
        if stripped != "- insert:":
            out.append(line)
            index += 1
            continue
        indent = _indent(line)
        probe = index + 1
        while probe < total and lines[probe].strip() == "":
            probe += 1
        has_child = False
        if probe < total:
            child = lines[probe]
            if _indent(child) > indent and child.lstrip().startswith("- "):
                has_child = True
        if has_child:
            out.append(line)
        index += 1
    return out


def _trim_trailing_blanks(lines):
    out = list(lines)
    while out and out[-1].strip() == "":
        out.pop()
    return out


def _append_block(lines, block_lines):
    """꼬리 공백을 정리하고, 내용이 있으면 빈 줄 하나를 둔 뒤 블록을 붙인다."""
    out = _trim_trailing_blanks(lines)
    if out:
        out.append("")
    out.extend(block_lines)
    return out


def _block_lines(path: Path):
    raw = Path(path).read_text(encoding="utf-8-sig")
    lines = [line.rstrip("\r") for line in raw.split("\n")]
    while lines and lines[-1].strip() == "":
        lines.pop()
    return lines


# ---------------------------------------------------------------- 명령


def patch_install(patch_path: Path, block_path: Path) -> int:
    lines, newline = read_lines(patch_path)
    before = len(lines)
    lines = remove_marked_block(lines, PATCH_BEGIN, PATCH_END)
    for item_id in MANAGED_ROW_IDS:
        lines = remove_list_item_by_id(lines, item_id)
    lines = remove_empty_insert_lists(lines)
    removed = before - len(lines)
    lines = _append_block(lines, _block_lines(block_path))
    write_lines(patch_path, lines, newline)
    # stdout 은 ASCII 로만 쓴다: LC_ALL=C 등 로캘이 ASCII 인 환경에서도 죽지 않게.
    print("cleaned %d line(s); managed block written" % removed)
    return 0


def patch_remove(patch_path: Path) -> int:
    if not patch_path.exists():
        print("absent")
        return 0
    lines, newline = read_lines(patch_path)
    before = len(lines)
    lines = remove_marked_block(lines, PATCH_BEGIN, PATCH_END)
    # 관리 블록 밖에 손으로 남은 중복 행/빈 insert 껍데기도 함께 정리한다.
    for item_id in MANAGED_ROW_IDS:
        lines = remove_list_item_by_id(lines, item_id)
    lines = remove_empty_insert_lists(lines)
    lines = _trim_trailing_blanks(lines)
    removed = before - len(lines)
    write_lines(patch_path, lines, newline)
    print("cleaned %d line(s)" % removed)
    return 0


def agents_install(agents_path: Path, section_path: Path) -> int:
    lines, newline = read_lines(agents_path)
    lines = remove_marked_block(lines, AGENTS_BEGIN, AGENTS_END)
    section = _block_lines(section_path)
    lines = _append_block(lines, [AGENTS_BEGIN] + section + [AGENTS_END])
    write_lines(agents_path, lines, newline)
    print("updated")
    return 0


def agents_remove(agents_path: Path) -> int:
    if not agents_path.exists():
        print("absent")
        return 0
    lines, newline = read_lines(agents_path)
    lines = remove_marked_block(lines, AGENTS_BEGIN, AGENTS_END)
    lines = _trim_trailing_blanks(lines)
    if not lines or all(line.strip() == "" for line in lines):
        agents_path.unlink()
        print("removed (no content left)")
        return 0
    write_lines(agents_path, lines, newline)
    print("cleaned")
    return 0


def patch_get(patch_path: Path, field: str) -> int:
    """관리 블록에서 단일 필드 값을 꺼내 stdout 에 출력한다(없으면 종료코드 1).

    verify 스크립트가 패치의 `command` / `args[0]` / `env.DSH_HOME` 을 실제 실행
    환경과 비교하기 위해 쓴다. 셸에서 YAML 을 긁는 것보다 안전하다.
    """
    lines, _ = read_lines(patch_path)
    patterns = {
        "command": re.compile(r"^\s*command:\s*'(.*)'\s*$"),
        "script": re.compile(r"^\s*-\s*'(.*dsh-web-search\.py)'\s*$"),
        "dsh_home": re.compile(r"^\s*DSH_HOME:\s*'(.*)'\s*$"),
        "timeout": re.compile(r"^\s*toolCallTimeoutMs:\s*(\S+)\s*$"),
    }
    pattern = patterns.get(field)
    if pattern is None:
        sys.stderr.write("unknown field: %s\n" % field)
        return 2
    inside = False
    for line in lines:
        trimmed = line.strip()
        if trimmed == PATCH_BEGIN:
            inside = True
            continue
        if trimmed == PATCH_END:
            break
        if not inside:
            continue
        match = pattern.match(line)
        if match:
            print(match.group(1).replace("''", "'"))
            return 0
    return 1


COMMANDS = {
    "patch-install": (patch_install, 2),
    "patch-remove": (patch_remove, 1),
    "patch-get": (patch_get, 2),
    "agents-install": (agents_install, 2),
    "agents-remove": (agents_remove, 1),
}


def main(argv) -> int:
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write(
            "usage: cordis_patch.py <patch-install|patch-remove|patch-get|agents-install|agents-remove> <path> [arg]\n"
        )
        return 2
    handler, arity = COMMANDS[argv[1]]
    args = argv[2:]
    if len(args) != arity:
        sys.stderr.write("wrong argument count for %s: expected %d\n" % (argv[1], arity))
        return 2
    # 첫 인자만 경로로 바꾼다(두 번째는 파일 경로일 수도, 필드 이름일 수도 있다).
    call_args = [Path(args[0])] + list(args[1:])
    return handler(*call_args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
