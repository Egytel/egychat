#!/usr/bin/env python3
"""Resolve egychat/Hatif merge conflicts against upstream Chatwoot by policy.

The fork survives upstream merges by keeping upstream's side and re-applying its brand
rule inside it - never by restoring our whole side of a file (that silently reverts
upstream's changes to shared files). Feature files where both sides added distinct code
are unioned, and files the fork deliberately trims keep our side.

A conflicted path with no policy ABORTS the run: the script never guesses.

Strategies (per path, in POLICY):
  theirs       - upstream's side verbatim
  theirs_brand - upstream's side, then the brand rule (standalone "Chatwoot" -> "Hatif")
  ours         - keep our side
  union        - composed from parts, each of which may be "ours", "theirs" or literal text

Usage:
  align_conflicts.py            # dry run: report what each conflicted file would get
  align_conflicts.py --apply    # rewrite the conflicted files (then run mark_resolved)
  align_conflicts.py --explain  # print the policy table
  align_conflicts.py --self-test# check the resolver against fixtures
"""
import json
import os
import re
import subprocess
import sys

APP_DIR = os.environ.get("CHATWOOT_DIR") or os.getcwd()
LOCALE_PREFIX = "app/javascript/dashboard/i18n/locale/en/"
WORD = re.compile(r"(?<![A-Za-z])Chatwoot(?![A-Za-z])")

POLICY = {
    # --- brand rule inside upstream's text ------------------------------------------
    f"{LOCALE_PREFIX}*": {"strategy": "theirs_brand"},
    "app/views/installation/onboarding/index.html.erb": {"strategy": "theirs_brand"},
    "app/views/super_admin/devise/sessions/new.html.erb": {"strategy": "theirs_brand"},
    # --- upstream's wording, backend locale is left unbranded by the fork -----------
    "config/locales/en.yml": {"strategy": "theirs"},
    # --- the fork deliberately trims upstream content -------------------------------
    "config/installation_config.yml": {"strategy": "ours"},
    # --- both sides added distinct code; compose them -------------------------------
    "app/services/whatsapp/webhook_setup_service.rb": {
        "strategy": "union",
        "parts": [
            {"src": "ours", "drop_blank": True},
            {"src": "theirs", "drop_blank": True},
        ],
        "blank_before": [r"^\s*def\s"],
    },
    "app/controllers/super_admin/app_configs_controller.rb": {
        "strategy": "union",
        "parts": [
            {"src": "ours"},
            {"src": "text", "value": "  ].freeze"},
            {"src": "theirs"},
        ],
    },
}


def policy_for(path):
    if path in POLICY:
        return POLICY[path]
    for pattern, entry in POLICY.items():
        if pattern.endswith("*") and path.startswith(pattern[:-1]):
            return entry
    return None


def conflicted_files():
    out = subprocess.run(["git", "-C", APP_DIR, "diff", "--name-only", "--diff-filter=U"],
                         capture_output=True, text=True, check=True).stdout
    return [line for line in out.split("\n") if line.strip()]


def parse_blocks(text):
    """Split into ('text', lines) and ('conflict', ours, theirs) parts."""
    lines = text.split("\n")
    parts, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("<<<<<<<"):
            i += 1
            ours = []
            while not lines[i].startswith("======="):
                ours.append(lines[i])
                i += 1
            i += 1
            theirs = []
            while not lines[i].startswith(">>>>>>>"):
                theirs.append(lines[i])
                i += 1
            i += 1
            parts.append(("conflict", ours, theirs))
            continue
        if line.startswith("=======") or line.startswith(">>>>>>>") or line.startswith("|||||||"):
            raise ValueError(f"stray conflict marker: {line!r}")
        parts.append(("text", [line]))
        i += 1
    return parts


def brand(lines):
    return [WORD.sub("Hatif", line) for line in lines]


def apply_policy(entry, ours, theirs):
    strategy = entry["strategy"]
    if strategy == "theirs":
        return list(theirs)
    if strategy == "theirs_brand":
        return brand(theirs)
    if strategy == "ours":
        return list(ours)
    if strategy == "union":
        out = []
        for part in entry["parts"]:
            src = part["src"]
            chunk = {"ours": ours, "theirs": theirs}.get(src, [part.get("value", "")])
            if part.get("drop_blank"):
                chunk = [line for line in chunk if line.strip()]
            if part.get("brand"):
                chunk = brand(chunk)
            out.extend(chunk)
        for pattern in entry.get("blank_before", []):
            final = []
            for line in out:
                if re.match(pattern, line) and final and final[-1].strip():
                    final.append("")
                final.append(line)
            out = final
        return out
    raise ValueError(f"unknown strategy: {strategy}")


def resolve_file(path, entry, apply_changes):
    with open(path, encoding="utf-8") as fh:
        parts = parse_blocks(fh.read())
    resolved, blocks = [], 0
    for part in parts:
        if part[0] == "text":
            resolved.extend(part[1])
            continue
        blocks += 1
        resolved.extend(apply_policy(entry, part[1], part[2]))
    text = "\n".join(resolved)
    if "<<<<<<<" in text or ">>>>>>>" in text:
        raise ValueError(f"{path}: markers survived resolution")
    if apply_changes:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    return blocks


def syntax_check(path):
    if path.endswith(".rb"):
        cmd = ["ruby", "-c", path]
    elif path.endswith(".json"):
        with open(path, encoding="utf-8") as fh:
            json.load(fh)
        return None
    elif path.endswith((".yml", ".yaml")):
        cmd = ["ruby", "-ryaml", "-e", f"YAML.load_file('{path}')"]
    else:
        return None
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=APP_DIR)
    return None if result.returncode == 0 else (result.stdout + result.stderr).strip()


def self_test():
    fixtures = [
        # (name, entry, ours, theirs, expected)
        ("theirs_brand view", POLICY["app/views/super_admin/devise/sessions/new.html.erb"],
         ['    <title>SuperAdmin | Hatif</title>'],
         ['    <meta name="robots" content="noindex">', '    <title>SuperAdmin | Chatwoot</title>'],
         ['    <meta name="robots" content="noindex">', "    <title>SuperAdmin | Hatif</title>"]),
        ("theirs verbatim", POLICY["config/locales/en.yml"],
         [], ["    billing:", "      invalid_currency: Invalid billing currency"],
         ["    billing:", "      invalid_currency: Invalid billing currency"]),
        ("ours", POLICY["config/installation_config.yml"],
         [], ["- name: CHATWOOT_SHOPIFY_PLANS", "  value: []"],
         []),
        ("union blank_before", POLICY["app/services/whatsapp/webhook_setup_service.rb"],
         ["  include Whatsapp::WebhookManagedExternally", ""],
         ["  attr_reader :registration_error", "", "  def initialize(channel, waba_id = nil, access_token = nil, is_coexistence: nil)"],
         ["  include Whatsapp::WebhookManagedExternally", "  attr_reader :registration_error", "",
          "  def initialize(channel, waba_id = nil, access_token = nil, is_coexistence: nil)"]),
        ("union controller", POLICY["app/controllers/super_admin/app_configs_controller.rb"],
         ["  WHATSAPP_EMBEDDED_CONFIG_KEYS = %w[", "    WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY"],
         ["  SHOPIFY_CONFIGS = %w[", "    ENABLE_SHOPIFY_INTEGRATION"],
         ["  WHATSAPP_EMBEDDED_CONFIG_KEYS = %w[", "    WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY",
          "  ].freeze", "  SHOPIFY_CONFIGS = %w[", "    ENABLE_SHOPIFY_INTEGRATION"]),
        ("brand word boundary", {"strategy": "theirs_brand"},
         [], ['"UPDATE_CHATWOOT": "An update {latestChatwootVersion} for Hatif is available."',
              '"X": "not a problem with Chatwoot."'],
         ['"UPDATE_CHATWOOT": "An update {latestChatwootVersion} for Hatif is available."',
          '"X": "not a problem with Hatif."']),
    ]
    failures = 0
    for name, entry, ours, theirs, expected in fixtures:
        got = apply_policy(entry, ours, theirs)
        ok = got == expected
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            print(f"      expected {expected}")
            print(f"      got      {got}")
    print(f"\nself-test: {len(fixtures) - failures}/{len(fixtures)} passed")
    return 1 if failures else 0


def main():
    if "--self-test" in sys.argv:
        return self_test()
    if "--explain" in sys.argv:
        for pattern, entry in POLICY.items():
            print(f"{pattern:<60} {entry['strategy']}")
        return 0

    files = conflicted_files()
    if not files:
        print("no conflicted files")
        return 0

    unknown, planned = [], []
    for path in files:
        entry = policy_for(path)
        (planned if entry else unknown).append((path, entry))

    if unknown:
        print("NO POLICY for these conflicted files - resolve them by hand and add a policy:")
        for path, _ in unknown:
            print(f"  {path}")
        print("\nPolicy table is in deployment/align_conflicts.py")
        return 2

    apply_changes = "--apply" in sys.argv
    failures = 0
    for path, entry in planned:
        full = f"{APP_DIR}/{path}"
        try:
            blocks = resolve_file(full, entry, apply_changes)
        except ValueError as exc:
            print(f"  FAIL {path}: {exc}")
            failures += 1
            continue
        print(f"  {'resolved' if apply_changes else 'would resolve'} {path} "
              f"[{entry['strategy']}, {blocks} block(s)]")
        if apply_changes:
            problem = syntax_check(path)
            if problem:
                print(f"  FAIL syntax after resolution: {path}\n{problem}")
                failures += 1

    if failures:
        print(f"\n{failures} file(s) failed - do not continue")
        return 1
    if apply_changes:
        subprocess.run(["git", "-C", APP_DIR, "add", "--"] + [p for p, _ in planned], check=True)
        print("\nall conflicted files resolved and staged")
    else:
        print("\ndry run only - pass --apply to rewrite")
    return 0


if __name__ == "__main__":
    sys.exit(main())
