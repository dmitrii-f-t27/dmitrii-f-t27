#!/usr/bin/env python3
"""Find candidate lines for the prompt-audit skill.

Usage: scan.py [path ...]
With no arguments, scans CLAUDE.md files, rules, skills, agents and commands
in the current project and in ~/.claude. A path may be a file or a directory
(directories are searched for *.md). Output is a list of places to read, not
a verdict: every hit still needs to be judged in context.
"""
import re
import sys
from pathlib import Path

DEFAULT_GLOBS = [
    "CLAUDE.md",
    "CLAUDE.local.md",
    "**/CLAUDE.md",
    ".claude/rules/**/*.md",
    ".claude/skills/*/SKILL.md",
    ".claude/agents/*.md",
    ".claude/commands/**/*.md",
]
HOME_GLOBS = [
    "CLAUDE.md",
    "rules/**/*.md",
    "skills/*/SKILL.md",
    "agents/*.md",
    "commands/**/*.md",
]
SKIP_DIRS = {"node_modules", ".git", "vendor", "dist", "build", ".venv"}

# Words that are uppercase for a reason and should not count as shouting.
ACRONYMS = {
    "API", "CLI", "CPU", "GPU", "CSS", "HTML", "HTTP", "HTTPS", "JSON", "YAML",
    "TOML", "SQL", "URL", "URI", "TDD", "CI", "CD", "PR", "MCP", "SDK", "LLM",
    "RTL", "FPGA", "ASIC", "README", "TODO", "FIXME", "NOTE", "MIT", "UTF",
    "AWS", "GCP", "SSH", "TLS", "JWT", "XSS", "CSRF", "OWASP", "CRUD", "REST",
    "ORM", "UI", "UX", "OS", "IO", "RAM", "DNS", "TCP", "UDP", "IP", "PDF",
    "CSV", "XML", "ENV", "PATH", "PASS", "FAIL", "OK", "N/A", "GF16", "VSA",
    "CLAUDE", "SKILL", "AGENTS", "LICENSE", "HIGH", "MEDIUM", "LOW",
}

CATEGORIES = [
    (
        "1-self-check",
        "request to double-check / re-verify own work",
        re.compile(
            r"double[- ]?check|re-?check|re-?verify|verify (?:it |everything |your )?twice"
            r"|check (?:it |everything )?(?:again|twice)|re-?read (?:your|the) (?:answer|response|output|work)"
            r"|review your (?:own )?(?:answer|response|output|work)|make sure (?:you are|you're|it is|it's) correct"
            r"|перепровер|провер\w* (?:ещё|еще) раз|дважды провер|провер\w* дважды|убедись,? что (?:ты )?прав",
            re.I,
        ),
    ),
    (
        "2-emphasis",
        "emphasis keyword (CRITICAL / IMPORTANT / MUST / NEVER / !!!)",
        re.compile(
            r"\b(?:CRITICAL|IMPORTANT|MUST|NEVER|ALWAYS|MANDATORY|REQUIRED|STRICTLY|ABSOLUTELY|UNDER NO CIRCUMSTANCES)\b"
            r"|\bYOU (?:MUST|SHOULD|WILL)\b|!{2,}|\*\*\*|extremely important|very important"
            r"|ВАЖНО|КРИТИЧНО|НИКОГДА|ВСЕГДА|ОБЯЗАТЕЛЬНО|СТРОГО|ЗАПРЕЩЕНО|очень важно"
        ),
    ),
    (
        "3-scripted-steps",
        "scripted procedure / generic thinking instruction",
        re.compile(
            r"think step[- ]by[- ]step|step[- ]by[- ]step|let'?s think|^\s*(?:#+\s*)?step \d+\b"
            r"|first,? (?:read|think|analy[sz]e|understand|plan)|before (?:you )?(?:answer|respond)ing,? (?:think|plan)"
            r"|шаг за шагом|^\s*(?:#+\s*)?шаг \d+|сначала (?:прочитай|подумай|проанализируй|пойми)",
            re.I,
        ),
    ),
    (
        "4-default-behavior",
        "restates default behavior",
        re.compile(
            r"you are an? (?:expert|senior|world[- ]class|helpful)|be helpful|best practices"
            r"|write (?:clean|good|correct|high[- ]quality) code|meaningful (?:variable )?names"
            r"|ты (?:эксперт|опытный|senior)|лучшие практики|чистый код",
            re.I,
        ),
    ),
]

CAPS_WORD = re.compile(r"\b[^\W\d_a-zа-яё]{3,}\b")


def shouting(line):
    words = [w for w in CAPS_WORD.findall(line) if w not in ACRONYMS and w.isupper()]
    return len(words) >= 3


def collect(args):
    files = []
    if args:
        for a in args:
            p = Path(a).expanduser()
            if p.is_dir():
                files += sorted(p.rglob("*.md"))
            elif p.is_file():
                files.append(p)
    else:
        cwd = Path.cwd()
        for g in DEFAULT_GLOBS:
            files += sorted(cwd.glob(g))
        home = Path.home() / ".claude"
        if home.is_dir():
            for g in HOME_GLOBS:
                files += sorted(home.glob(g))
    seen, out = set(), []
    for f in files:
        if any(part in SKIP_DIRS for part in f.parts):
            continue
        r = f.resolve()
        if r not in seen:
            seen.add(r)
            out.append(f)
    return out


def scan(path):
    hits = []
    in_fence = False
    in_front = False
    text = path.read_text(encoding="utf-8", errors="replace")
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if n == 1 and stripped == "---":
            in_front = True
            continue
        if in_front:
            if stripped == "---":
                in_front = False
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for key, _, rx in CATEGORIES:
            if rx.search(line):
                hits.append((key, n, stripped))
        if shouting(line):
            hits.append(("2-caps", n, stripped))
    return text, hits


def main():
    files = collect(sys.argv[1:])
    if not files:
        print("No instruction files found. Pass paths explicitly: scan.py CLAUDE.md .claude/")
        return 1
    labels = {k: d for k, d, _ in CATEGORIES}
    labels["2-caps"] = "three or more ALL-CAPS words on one line"

    total_tokens = 0
    report = []
    print("== Files (approx. tokens = characters / 4) ==")
    for f in files:
        text, hits = scan(f)
        tokens = len(text) // 4
        total_tokens += tokens
        print(f"{tokens:>7}  {f}  ({len(hits)} hits)")
        report.append((f, hits))
    print(f"{total_tokens:>7}  total\n")

    for f, hits in report:
        if not hits:
            continue
        print(f"== {f} ==")
        for key in sorted({h[0] for h in hits}):
            print(f"  [{key}] {labels[key]}")
            for k, n, s in hits:
                if k == key:
                    print(f"    {n:>5}: {s[:160]}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
