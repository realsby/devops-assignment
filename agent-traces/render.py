"""Render subagent-session.jsonl (the raw, unedited trace) as Markdown.

    python3 agent-traces/render.py > agent-traces/subagent-session.md

Lead-agent prompts and the subagent's text are shown in full. Tool calls
are shown with their input; tool output is cut to the first lines to keep
the file readable (the JSONL has everything).
"""
import json
import sys
from pathlib import Path

SRC = Path(__file__).with_name("subagent-session.jsonl")
MAX_OUT_LINES = 15


def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block["text"])
    return "\n".join(parts)


def short(s, lines=MAX_OUT_LINES):
    rows = s.splitlines()
    if len(rows) <= lines:
        return s
    return "\n".join(rows[:lines]) + f"\n... ({len(rows) - lines} more lines in the jsonl)"


def main():
    out = sys.stdout
    out.write("# Subagent session (rendered)\n\n")
    out.write("Lead agent (Claude Opus 5.5) ↔ implementation subagent (Claude Sonnet 5). "
              "Rendered from `subagent-session.jsonl`, which is the unedited source.\n\n")
    for line in SRC.open():
        d = json.loads(line)
        kind = d.get("type")
        msg = d.get("message") or {}
        ts = (d.get("timestamp") or "")[:19].replace("T", " ")
        content = msg.get("content")
        if kind == "user":
            if isinstance(content, str) or any(
                isinstance(b, dict) and b.get("type") == "text" for b in content or []
            ):
                t = text_of(content).strip()
                if t:
                    if t.startswith("This session is being continued"):
                        label = "Harness: context summary (subagent ran out of context)"
                    elif t.startswith("<system-reminder>") or t.startswith("Your response above was cut off"):
                        label = "Harness message"
                    else:
                        label = "Lead → subagent"
                    out.write(f"\n---\n\n## {label}  <sub>{ts}</sub>\n\n{t}\n\n")
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    res = b.get("content")
                    res = text_of(res) if isinstance(res, list) else str(res or "")
                    out.write("<details><summary>tool output</summary>\n\n```\n"
                              f"{short(res).replace('```', '` ` `')}\n```\n</details>\n\n")
        elif kind == "assistant":
            for b in content or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b["text"].strip():
                    out.write(f"**Subagent** <sub>{ts}</sub>\n\n{b['text'].strip()}\n\n")
                elif b.get("type") == "tool_use":
                    inp = b.get("input", {})
                    shown = inp.get("command") or inp.get("file_path") or json.dumps(inp)[:400]
                    out.write(f"`{b.get('name')}`: `{str(shown)[:400].replace('`', '')}`\n\n")


if __name__ == "__main__":
    main()
