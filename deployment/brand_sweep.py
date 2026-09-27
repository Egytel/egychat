#!/usr/bin/env python3
"""Re-apply the Hatif brand rule to dashboard locale strings upstream added.

After merging an upstream Chatwoot release, the *auto-merged* regions can quietly bring
back user-facing "Chatwoot" strings (only the conflicted hunks get reviewed). This script
rewrites those, and only those:

  * JSON *values* only - a key name is never renamed, so UPDATE_CHATWOOT stays,
  * "Chatwoot" is replaced only when it is a standalone word, so placeholders such as
    {latestChatwootVersion} keep working,
  * lines without a key/value separator are reported, never guessed at,
  * every rewritten file is re-parsed as JSON before the script exits.

Usage:
  python3 deployment/brand_sweep.py            # dry run, prints what it would change
  python3 deployment/brand_sweep.py --apply    # rewrite in place
"""
import json
import os
import re
import sys

ROOT = os.environ.get("CHATWOOT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCALE_DIR = os.path.join(ROOT, "app/javascript/dashboard/i18n/locale/en")
WORD = re.compile(r"(?<![A-Za-z])Chatwoot(?![A-Za-z])")
APPLY = "--apply" in sys.argv

if not os.path.isdir(LOCALE_DIR):
    sys.exit(f"locale directory not found: {LOCALE_DIR}")

total = 0
for name in sorted(os.listdir(LOCALE_DIR)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(LOCALE_DIR, name)
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    hits, skipped = 0, []
    for i, line in enumerate(lines):
        if "Chatwoot" not in line:
            continue
        sep = line.find('": ')
        if sep == -1:
            skipped.append(i + 1)
            continue
        head, value = line[: sep + 3], line[sep + 3 :]
        new_value, n = WORD.subn("Hatif", value)
        if n:
            lines[i] = head + new_value
            hits += n
    if hits:
        total += hits
        print(f"{name}: {hits} value occurrence(s)")
        if APPLY:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines))
            with open(path, encoding="utf-8") as fh:
                json.load(fh)
    if skipped:
        print(f"  {name}: lines without a key/value separator left alone: {skipped}")

print(f"total: {total} occurrence(s) | mode: {'APPLIED' if APPLY else 'DRY RUN'}")
