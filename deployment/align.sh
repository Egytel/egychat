#!/usr/bin/env bash
#
# align.sh
#
# Align the whitelabeled EgyChat fork with the upstream Chatwoot repository while
# preserving the EgyChat branding / white-label.
#
#   1. Fetch the latest upstream Chatwoot `master` branch.
#   2. Merge it into the current branch, then re-apply our branding on top.
#   3. Run the required database migrations.
#   4. Rebuild assets and restart services so the changes take effect.
#
# Usage:
#   Run from inside the Chatwoot checkout, or point CHATWOOT_DIR at it:
#     CHATWOOT_DIR=/home/chatwoot/chatwoot ./deployment/align.sh
#
# Run as root (the `chatwoot` service user is used for Rails commands when present).

set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/chatwoot/chatwoot.git"
UPSTREAM_BRANCH="master"
PRIVATE_BRANCH="private/main"
BRAND_COMMIT_MSG="chore(branding): re-apply EgyChat white-label after upstream align"

# The checkout to operate on. Defaults to the repo that contains this script.
APP_DIR="${CHATWOOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$APP_DIR"

# --- sanity checks -------------------------------------------------------------
[ -d .git ] || die "not a git repository: $APP_DIR"
git rev-parse --verify "$PRIVATE_BRANCH" >/dev/null 2>&1 || \
  die "branch '$PRIVATE_BRANCH' not found locally; fetch it first (git fetch origin $PRIVATE_BRANCH)"
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree is not clean; commit or stash your changes before aligning"
fi
CURRENT_BRANCH="$(git branch --show-current)"
echo "Aligning branch '$CURRENT_BRANCH' in $APP_DIR"

# --- 1. Fetch upstream master --------------------------------------------------
log "1/4 Fetching upstream Chatwoot ($UPSTREAM_BRANCH)"
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

# Branding / white-label = every file our branch changes relative to upstream.
BASE="$(git merge-base "$PRIVATE_BRANCH" "$UPSTREAM_REF")"
[ -n "$BASE" ] || die "no common ancestor between $PRIVATE_BRANCH and $UPSTREAM_REF"
mapfile -d '' -t BRANDING_FILES < <(git diff --name-only -z "$BASE" "$PRIVATE_BRANCH")
echo "Tracking ${#BRANDING_FILES[@]} branding/white-label file(s)."

# --- 2. Merge upstream, then re-apply branding --------------------------------
log "2/4 Merging $UPSTREAM_REF into '$CURRENT_BRANCH'"
# Snapshot our branding before the merge so we can restore it afterwards.
PRE_MERGE_REF="refs/align/pre-merge"
git update-ref "$PRE_MERGE_REF" HEAD

if ! git merge "$UPSTREAM_REF" --no-edit; then
  echo "Merge reported conflicts; they will be resolved by re-applying branding."
fi

log "Re-applying branding/white-label from $PRIVATE_BRANCH"
if [ "${#BRANDING_FILES[@]}" -gt 0 ]; then
  git checkout "$PRE_MERGE_REF" -- "${BRANDING_FILES[@]}"
fi
git update-ref -d "$PRE_MERGE_REF"

git add -A
# Any remaining unmerged (non-branding) files must be resolved by hand.
if git ls-files -u | grep -q .; then
  git ls-files -u
  die "unresolved merge conflicts remain; resolve them manually and commit"
fi

if git diff --cached --quiet; then
  echo "No branding changes to commit."
else
  git commit -m "$BRAND_COMMIT_MSG"
fi

# --- Rails command helper (runs as the `chatwoot` user when present) -----------
run_rails() {
  local cmd="$1"
  if [ "$(id -u)" -eq 0 ] && id -u chatwoot >/dev/null 2>&1; then
    sudo -i -u chatwoot bash -lc "cd '$APP_DIR' && $cmd"
  else
    bash -lc "cd '$APP_DIR' && $cmd"
  fi
}

# --- 3. Run database migrations ------------------------------------------------
log "3/4 Running database migrations"
run_rails 'RAILS_ENV=production POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:migrate'

# --- 4. Rebuild assets + restart services --------------------------------------
log "4/4 Rebuilding assets (so branding takes effect) and restarting services"
run_rails 'RAILS_ENV=production NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider" bundle exec rails assets:precompile'

if [ -f /etc/systemd/system/chatwoot.target ]; then
  systemctl restart chatwoot.target
  echo "Restarted chatwoot.target"
elif [ -f /etc/systemd/system/chatwoot-web.target ]; then
  systemctl restart chatwoot-web.target
  echo "Restarted chatwoot-web.target"
else
  echo "No Chatwoot systemd target found; restart the app manually."
fi

log "Align complete: upstream $UPSTREAM_BRANCH + EgyChat branding."
