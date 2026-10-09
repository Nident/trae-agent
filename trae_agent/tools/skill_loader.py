#!/usr/bin/env python3
"""
Skill loader for Trae Agent.

Progressive disclosure:
  Level 1 — list:   prints name + description (~50 tokens per skill)
  Level 2 — load:   prints full SKILL.md body (< 5000 tokens)
  Level 3 — read:   prints a referenced file from skill directory

Usage (called by agent via bash tool):
  python3 tools/skill_loader.py list
  python3 tools/skill_loader.py load python-sast
  python3 tools/skill_loader.py read python-sast references/pandas_eval.md
"""

from __future__ import annotations

import sys
import re
from pathlib import Path

SKILLS_ROOT = Path(__file__).resolve().parent.parent / "skills"


# ── frontmatter parser (no yaml dependency) ──────────────────────────

def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Return (metadata_dict, body) from a SKILL.md file.

    Handles single-line values, quoted strings, and multi-line
    folded/literal block scalars (> and |).
    """
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text

    meta: dict[str, str] = {}
    current_key: str | None = None
    current_lines: list[str] = []

    def _flush() -> None:
        if current_key is not None:
            value = " ".join(current_lines).strip().strip("\"'")
            meta[current_key] = value

    for line in parts[1].strip().splitlines():
        # new key: value  OR  key: >  OR  key: |
        m = re.match(r"^(\w[\w-]*)\s*:\s*(.*)", line)
        if m:
            _flush()
            current_key = m.group(1)
            val = m.group(2).strip()
            if val in (">", "|", ">-", "|-"):
                current_lines = []          # block scalar follows
            else:
                current_lines = [val] if val else []
        elif current_key is not None and line.startswith("  "):
            # continuation line (indented)
            current_lines.append(line.strip())

    _flush()
    return meta, parts[2]


# ── commands ─────────────────────────────────────────────────────────

def cmd_list() -> None:
    """Level 1: advertise all available skills (name + description)."""
    skills = sorted(SKILLS_ROOT.iterdir())
    print("Available skills:")
    print()
    for skill_dir in skills:
        md = skill_dir / "SKILL.md"
        if not md.is_file():
            continue
        meta, _ = parse_frontmatter(md.read_text())
        name = meta.get("name", skill_dir.name)
        desc = meta.get("description", "(no description)")
        print(f"  {name}")
        print(f"    {desc}")
        print()


def cmd_load(skill_name: str) -> None:
    """Level 2: load full SKILL.md instructions into context."""
    skill_dir = SKILLS_ROOT / skill_name
    md = skill_dir / "SKILL.md"
    if not md.is_file():
        print(f"ERROR: skill '{skill_name}' not found at {md}", file=sys.stderr)
        sys.exit(1)
    _, body = parse_frontmatter(md.read_text())
    print(body.strip())

    # hint about available resources
    resources = []
    for sub in ("references", "scripts"):
        d = skill_dir / sub
        if d.is_dir():
            resources.extend(
                f"{sub}/{f.name}" for f in sorted(d.iterdir()) if f.is_file()
            )
    if resources:
        print()
        print("Referenced files available (load with: "
              f"python3 tools/skill_loader.py read {skill_name} <path>):")
        for r in resources:
            print(f"  {r}")


def cmd_read(skill_name: str, resource_path: str) -> None:
    """Level 3: read a referenced file from skill directory."""
    target = (SKILLS_ROOT / skill_name / resource_path).resolve()
    # safety: must stay inside skills root
    if not str(target).startswith(str(SKILLS_ROOT.resolve())):
        print("ERROR: path escapes skills directory", file=sys.stderr)
        sys.exit(1)
    if not target.is_file():
        print(f"ERROR: resource not found: {target}", file=sys.stderr)
        sys.exit(1)
    print(target.read_text())


# ── main ─────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: skill_loader.py {list|load|read} [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    match cmd:
        case "list":
            cmd_list()
        case "load":
            if len(sys.argv) < 3:
                print("Usage: skill_loader.py load <skill-name>", file=sys.stderr)
                sys.exit(1)
            cmd_load(sys.argv[2])
        case "read":
            if len(sys.argv) < 4:
                print("Usage: skill_loader.py read <skill> <path>", file=sys.stderr)
                sys.exit(1)
            cmd_read(sys.argv[2], sys.argv[3])
        case _:
            print(f"Unknown command: {cmd}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
