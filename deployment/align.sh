#!/usr/bin/env bash
#
# align.sh
#
# Align the whitelabeled EgyChat fork with the upstream Chatwoot repository while
# preserving the EgyChat branding / white-label.
#
#   1. Fetch the latest upstream Chatwoot `master` branch.
#   2. Merge it into the current branch, then re-apply our branding on top.
#   3. Install Ruby & JS dependencies for the merged code (bundle + pnpm).
#   4. Run the required database migrations and rebuild production assets.
#   5. Restart services so the changes take effect.
#
# Usage:
#   Run as root on the server. The script operates on the deployed checkout at
#   /home/chatwoot/chatwoot by default (where the app runs and the DB lives).
#   Point CHATWOOT_DIR elsewhere to target a different checkout.
#     CHATWOOT_DIR=/home/chatwoot/chatwoot ./deployment/align.sh
#
# All git and Rails operations run as the `chatwoot` service user so that the
# files it owns stay owned by chatwoot. Only the service restart needs root.

set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/chatwoot/chatwoot.git"
UPSTREAM_BRANCH="master"
PRIVATE_BRANCH="private/main"
BRAND_COMMIT_MSG="chore(branding): re-apply EgyChat white-label after upstream align"

# The checkout to operate on. Default to the deployed Chatwoot when present;
# otherwise fall back to CHATWOOT_DIR or the repo that contains this script.
if [ -n "${CHATWOOT_DIR:-}" ]; then
  APP_DIR="$CHATWOOT_DIR"
elif [ "$(id -u)" -eq 0 ] && id -u chatwoot >/dev/null 2>&1 && [ -d /home/chatwoot/chatwoot/.git ]; then
  APP_DIR="/home/chatwoot/chatwoot"
else
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# When running as root on a server with a `chatwoot` user, run repo/Rails
# commands as chatwoot so files stay owned by the service user.
CW_USER=""
if [ "$(id -u)" -eq 0 ] && id -u chatwoot >/dev/null 2>&1; then
  CW_USER="chatwoot"
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Run a git command in $APP_DIR, as the chatwoot user when needed.
# NOTE: uses `sudo -u ... -H` (no login shell) so git output stays clean.
git_() {
  if [ -n "$CW_USER" ]; then
    sudo -u "$CW_USER" -H git -C "$APP_DIR" "$@"
  else
    git -C "$APP_DIR" "$@"
  fi
}

# Run a Rails command in $APP_DIR, as the chatwoot user (login shell loads RVM).
rails_() {
  local cmd="$1"
  if [ -n "$CW_USER" ]; then
    sudo -i -u "$CW_USER" bash -lc "cd '$APP_DIR' && $cmd"
  else
    bash -lc "cd '$APP_DIR' && $cmd"
  fi
}

restart_chatwoot() {
  local unit=""
  if [ -f /etc/systemd/system/chatwoot.target ]; then
    unit="chatwoot.target"
  elif [ -f /etc/systemd/system/chatwoot-web.target ]; then
    unit="chatwoot-web.target"
  fi

  if [ -n "$unit" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      /bin/systemctl restart "$unit"
    else
      sudo /bin/systemctl restart "$unit"
    fi
    echo "Restarted $unit"
  else
    echo "No Chatwoot systemd target found; restart the app manually."
  fi
}

# --- sanity checks -------------------------------------------------------------
[ -d "$APP_DIR/.git" ] || die "not a git repository: $APP_DIR"
git_ rev-parse --verify "$PRIVATE_BRANCH" >/dev/null 2>&1 || \
  die "branch '$PRIVATE_BRANCH' not found; fetch it first (git fetch origin $PRIVATE_BRANCH)"
if ! git_ diff --quiet || ! git_ diff --cached --quiet; then
  die "working tree is not clean; commit or stash your changes before aligning"
fi
CURRENT_BRANCH="$(git_ branch --show-current)"
echo "Aligning branch '$CURRENT_BRANCH' in $APP_DIR"

# Ensure a git identity is configured for the merge/branding commits.
if [ -z "$(git_ config user.email)" ]; then
  git_ config user.name "Chatwoot Deploy"
  git_ config user.email "deploy@$(hostname)"
  echo "Configured git identity for commits."
fi

# --- 1. Fetch upstream master --------------------------------------------------
log "1/5 Fetching upstream Chatwoot ($UPSTREAM_BRANCH)"
if ! git_ remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git_ remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi
git_ fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

# Branding / white-label = every file our branch changes relative to upstream.
BASE="$(git_ merge-base "$PRIVATE_BRANCH" "$UPSTREAM_REF")"
[ -n "$BASE" ] || die "no common ancestor between $PRIVATE_BRANCH and $UPSTREAM_REF"
mapfile -d '' -t BRANDING_FILES < <(git_ diff --name-only -z "$BASE" "$PRIVATE_BRANCH")
echo "Tracking ${#BRANDING_FILES[@]} branding/white-label file(s)."

# --- 2. Merge upstream, then re-apply branding --------------------------------
log "2/5 Merging $UPSTREAM_REF into '$CURRENT_BRANCH'"
# Snapshot our branding before the merge so we can restore it afterwards.
PRE_MERGE_REF="refs/align/pre-merge"
git_ update-ref "$PRE_MERGE_REF" HEAD

if ! git_ merge "$UPSTREAM_REF" --no-edit; then
  if git_ ls-files -u | grep -q .; then
    echo "Merge conflicts detected; they will be resolved by re-applying branding."
  else
    die "git merge failed (not due to conflicts). Aborting."
  fi
fi

log "Re-applying branding/white-label from $PRIVATE_BRANCH"
if [ "${#BRANDING_FILES[@]}" -gt 0 ]; then
  git_ checkout "$PRE_MERGE_REF" -- "${BRANDING_FILES[@]}"
fi
git_ update-ref -d "$PRE_MERGE_REF"

git_ add -A
# Any remaining unmerged (non-branding) files must be resolved by hand.
if git_ ls-files -u | grep -q .; then
  git_ ls-files -u
  die "unresolved merge conflicts remain; resolve them manually and commit"
fi

if git_ diff --cached --quiet; then
  echo "No branding changes to commit."
else
  git_ commit -m "$BRAND_COMMIT_MSG"
fi

# --- 3. Install dependencies (required after merging new upstream code) ---------
log "3/5 Installing Ruby and JS dependencies"
rails_ 'bundle install'
rails_ 'pnpm install'

# --- 4. Migrate DB + rebuild assets ---------------------------------------------
log "4/5 Running database migrations"
rails_ 'RAILS_ENV=production POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:migrate'

log "Rebuilding assets (so branding takes effect)"
rails_ 'RAILS_ENV=production NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider" bundle exec rails assets:precompile'

# --- 5. Restart services ---------------------------------------------------------
log "5/5 Restarting services"
restart_chatwoot

log "Align complete: upstream $UPSTREAM_BRANCH + EgyChat branding."
