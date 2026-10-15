---
name: prompt-audit
description: Audit CLAUDE.md, rules, skills, agents and slash commands for instructions written for older models that now slow newer Claude models down — requests to double-check work, ALL-CAPS / MUST / CRITICAL emphasis, and step-by-step scripts for things the model already does well. Shows every proposed cut or rewrite and applies changes only after approval. Use when the user asks to audit, clean up, slim down or modernize CLAUDE.md, skills or prompts, or when responses got slower, more expensive or more over-cautious after a model upgrade.
license: MIT
---

# Prompt Audit

CLAUDE.md, rules and skill descriptions are loaded into context on every turn, so each line costs tokens on every request and shapes every answer. Instructions that were needed to keep older models on track often hurt newer ones: current models follow instructions closely, so emphasis that used to compensate for inattention now makes them over-apply a rule, and scripted procedures stop them from using their own judgment. This skill finds those instructions and proposes a leaner version.

## Scope

Ask which scope the user wants if it is unclear; default to the current project plus the user's global config:

- `CLAUDE.md`, `CLAUDE.local.md` and nested `**/CLAUDE.md` in the project
- `~/.claude/CLAUDE.md`
- `.claude/rules/**/*.md`, `~/.claude/rules/**/*.md`
- `.claude/skills/*/SKILL.md`, `~/.claude/skills/*/SKILL.md`
- `.claude/agents/*.md`, `~/.claude/agents/*.md`
- `.claude/commands/**/*.md`, `~/.claude/commands/**/*.md`

## Process

1. **Inventory.** Run `scripts/scan.sh [paths...]` from this skill's directory (with no arguments it scans the default scope above). It lists the files with their size and an approximate token count, then candidate lines grouped by category. The scan is a grep heuristic: it only points at places to read.
2. **Judge each candidate in context.** Read the surrounding section before deciding. Typical false positives: identifiers and env vars (`HTTPS_PROXY`, `API_KEY`), acronyms (`JSON`, `HTTP`, `TDD`), severity labels in a review rubric (`CRITICAL | HIGH | LOW` as categories, not as emphasis), RFC 2119 wording inside quoted specs, and verification steps that run real tools. Also read each file in full once, because some problems (duplicates, contradictions, stale facts) never match a pattern.
3. **Report before editing.** For every finding give: `file:line`, category, the current text, the proposed replacement (or "delete"), and one line on why. Group by file, put the biggest token savings first, and end with a before/after token estimate per file. Write the report in the user's language.
4. **Apply only what the user approves.** The user may accept everything, pick findings by number, or reject some. Edit with minimal diffs, keep the file's language and structure, then show the final diff and the new token counts.

Never edit vendored or upstream-synced files (for example a starter kit that is periodically synced from another repo) without pointing out that the next sync will overwrite the change; suggest overriding the rule in the user's own CLAUDE.md instead.

## What to look for

### 1. Requests to double-check work

Examples: "double-check your answer", "re-read your work before responding", "verify everything twice", "make sure you are correct", "review your output for errors before finishing".

Why it hurts: current models already check their work. A generic request to re-check triggers extra passes over the same reasoning, which costs tokens and time and tends to produce hedged, over-qualified answers rather than more correct ones.

Fix: delete generic self-checks. Keep, or rewrite into, concrete verification that uses tools and project knowledge, because that is information the model does not have: "run `zig build test` before saying a change is done", "check the generated RTL with `yosys -p synth`".

### 2. Shouting and emphasis

Examples: whole sentences in capitals, `CRITICAL:`, `IMPORTANT:`, `YOU MUST`, `NEVER EVER`, `!!!`, stacked bold, "this is extremely important".

Why it hurts: emphasis was a way to get attention from models that skimmed instructions. Current models read everything, so emphasis makes them treat the rule as overriding everything else and apply it where it does not fit (refusing reasonable actions, asking permission constantly, over-applying a style rule).

Fix: state the rule once, in normal case, with its reason. The reason does more work than the capitals did, because it lets the model judge edge cases.

- Before: `NEVER commit directly to main!!! THIS IS CRITICAL.`
- After: `Commit to a feature branch, not main: main deploys automatically.`

Keep the substance of safety and security rules; only change the tone.

### 3. Step-by-step scripts for things the model already does

Examples: "Step 1: read the file. Step 2: understand the code. Step 3: think about the change…", "think step by step", "first make a plan, then…", long checklists of generic engineering advice ("write clean code", "handle errors", "use meaningful names"), instructions on how to use built-in tools.

Why it hurts: fixed procedures replace the model's own planning with a worse generic one, force ceremony on small tasks, and cost tokens on every turn.

Fix: replace the procedure with the goal and the constraints that are specific to this project. Keep steps whose order really matters or that encode local knowledge (commands, environments, non-obvious gotchas).

- Before: a 12-step "how to fix a bug" procedure.
- After: `Reproduce bugs with a failing test in tests/ before fixing; CI runs only tests/, not examples/.`

### Additional checks

- **Default behavior restated**: "be helpful", "write correct code", "follow best practices", "you are an expert engineer". Delete.
- **Duplicates**: the same rule in CLAUDE.md, a rules file and a skill. Keep it in one place.
- **Contradictions**: two rules that cannot both be followed. Ask the user which one wins.
- **Stale facts**: old model names, removed commands or paths, tools the project no longer uses. Check paths and commands exist (`ls`, `which`, grep the repo) before flagging.
- **Rules without reasons**: add the reason when it is known; ask the user when it is not.
- **Only-negative instructions**: "don't use X" without saying what to do instead. Rephrase as what to do.
- **Bloated skill descriptions**: the `description` frontmatter of every skill loads into each session. It should say what the skill does and when to use it, in a few sentences, not contain the instructions themselves.
- **Content that belongs elsewhere**: long reference material (API docs, full style guides) that is needed only sometimes. Suggest moving it to a separate file the model reads on demand, referenced from CLAUDE.md by path.

## What to keep

Project-specific commands and paths, architecture facts the model cannot infer from the code quickly, team conventions, security and data-handling constraints, and anything the user confirms they rely on. When unsure whether a line still earns its place, list it as "question" in the report instead of proposing deletion.
