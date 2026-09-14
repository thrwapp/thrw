#!/usr/bin/env python3
"""Score an agent-task issue for completeness against the issue template.

STUB: this does not call Gemini Flash / Vertex AI yet. It runs a cheap
local heuristic (are the agent-task.yml sections filled in?) so
agent-triage.yml has something deterministic to branch on before GCP is
set up, and so the workflow doesn't hard-fail during initial setup.

TODO(agent-triage): replace the heuristic in `score_issue` below with a
real call to Gemini Flash via Vertex AI (see ADR 0008), grading the issue
against the full agent-task.yml completeness bar rather than just
checking the sections are non-empty.
"""

import os
import re
import sys


SECTION_HEADERS = (
    "Package/service path",
    "Acceptance criteria",
    "Test command",
)


def score_issue(body: str) -> tuple[float, list[str]]:
    """Return (score in [0, 1], list of missing/empty sections)."""
    missing = []
    for header in SECTION_HEADERS:
        pattern = rf"###\s*{re.escape(header)}\s*\n+\s*(\S.*)"
        match = re.search(pattern, body, re.IGNORECASE)
        if not match or match.group(1).strip().lower() in ("_no response_", ""):
            missing.append(header)

    score = (len(SECTION_HEADERS) - len(missing)) / len(SECTION_HEADERS)
    return score, missing


def main() -> int:
    print("TODO: this is a stub. Replace with a real Gemini Flash call via "
          "Vertex AI once GCP_PROJECT_AI is live (see ADR 0008).")

    body = os.environ.get("ISSUE_BODY", "")
    score, missing = score_issue(body)

    print(f"Heuristic completeness score: {score:.2f}")
    if missing:
        print(f"Missing or empty sections: {', '.join(missing)}")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as fh:
            fh.write(f"score={score:.2f}\n")
            fh.write(f"missing={', '.join(missing)}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
