#!/usr/bin/env python3
"""Draft and post a release announcement.

STUB: does not call Gemini Flash or post anywhere yet. Per SOCIAL.md,
this must never post to Reddit or Hacker News regardless of what it's
later filled in to do.

TODO(release): call Gemini Flash via Vertex AI (ADR 0008) to draft the
post from the release tag/notes, respecting SOCIAL.md's voice and rules,
then actually post it wherever thrw's release announcements go.
"""

import os
import sys


def main() -> int:
    tag = os.environ.get("RELEASE_TAG", "<unknown tag>")
    print("TODO: this is a stub. Replace with a real Gemini Flash draft "
          "(ADR 0008) and an actual post, respecting SOCIAL.md.")
    print(f"Would have drafted and posted a release announcement for {tag}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
