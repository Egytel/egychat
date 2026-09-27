#!/usr/bin/env bash
#
# align.sh
#
# Align the Hatif fork with the upstream Chatwoot repository while preserving the Hatif
# branding and the fork's own patches.
#
#   0. Back up the database, the built assets, .env and the commit we started from.
#   1. Fetch upstream and pick the target: the newest release tag by default (master can
#      carry unreleased code), or ALIGN_TAG=<ref>.
#   2. Merge it into our branch; resolve conflicts by policy (deployment/align_conflicts.py:
#      upstream's side + our brand rule, unioned where both sides added code) and re-apply
#      the brand rule to strings upstream added (deployment/brand_sweep.py).
#   3. Verify the fork's customizations are still intact (deployment/verify_customizations.sh)
#      - this gate runs BEFORE anything is installed, migrated or restarted.
#   4. Install Ruby & JS dependencies, run migrations, rebuild the front end
#      (`pnpm run build:sdk` + `bin/vite build`).
#   5. Restart services and smoke-test the result (origin, manifest chunk, every referenced
#      asset, and the public URL when PUBLIC_URL is set).
#   6. Push the private branch (skippable with ALIGN_PUSH=0) and print the rollback recipe.
#
# Usage (as root on the server; the checkout defaults to /home/chatwoot/chatwoot):
#   ./deployment/align.sh                       # newest upstream release tag
#   ALIGN_TAG=v4.19.0 ./deployment/align.sh     # a specific release
#   ALIGN_TAG=master  ./deployment/align.sh     # upstream master
#   ALIGN_DRY_RUN=1   ./deployment/align.sh     # merge + resolve + verify on a scratch
#                                               # branch, then undo it: nothing restarted
#   ALIGN_ROLLBACK=1  ./deployment/align.sh     # restore git + .env + assets from the newest
#                                               # backup set (add ALIGN_ROLLBACK_DB=1 to also
#                                               # restore the database)
#
# All git and Rails operations run as the `chatwoot` service user so that the files it owns
# stay owned by chatwoot; the push needs root's GitHub key, and only the service restart
# needs root.
#
# FLOW NOTE (validated on chatsdev 2026-09-27, v4.16.2 -> v4.17.1 -> v4.18.0):
#   * conflicts are resolved by KEEPING UPSTREAM'S SIDE and re-applying the brand rule
#     inside it - never by restoring our whole side of a file, otherwise upstream's changes
#     to shared files (WhatsApp services, config/locales/en.yml, the dashboard en/*.json
#     locales) are silently reverted,
#   * a conflicted path without a policy ABORTS the run rather than guessing,
#   * `assets:precompile` is deliberately not used: it also regenerates the sprockets
#     public/assets tree this fork prunes and bundles the widget SDK itself.

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="https://github.com/chatwoot/chatwoot.git"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
PRIVATE_REMOTE="${PRIVATE_REMOTE:-egytel}"
PRIVATE_BRANCH="${PRIVATE_BRANCH:-private/main}"
ALIGN_TAG="${ALIGN_TAG:-}"
ALIGN_DRY_RUN="${ALIGN_DRY_RUN:-0}"
ALIGN_PUSH="${ALIGN_PUSH:-1}"
ALIGN_ROLLBACK="${ALIGN_ROLLBACK:-0}"
ALIGN_ROLLBACK_DB="${ALIGN_ROLLBACK_DB:-0}"
PUBLIC_URL="${PUBLIC_URL:-}"
BRAND_COMMIT_MSG="chore(branding): re-apply Hatif white-label after upstream align"
BRAND_SWEEP_MSG="chore(branding): re-apply the Hatif brand rule to strings upstream added"

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

BACKUP_DIR="${BACKUP_DIR:-/root/backups}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

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

# The front-end build tells us which chunk the app should be serving.
manifest_chunk() {
  python3 -c "import json;print(json.load(open('$APP_DIR/public/vite/.vite/manifest.json'))['entrypoints/dashboard.js']['file'])" 2>/dev/null || echo ""
}

app_version() {
  grep -m1 'version:' "$APP_DIR/config/app.yml" | tr -d " 'version:" || echo "?"
}

# Push must only ever target the private fork.
assert_private_remote() {
  local url lower
  url="$(git_ remote get-url "$PRIVATE_REMOTE" 2>/dev/null || true)"
  [ -n "$url" ] || die "no '$PRIVATE_REMOTE' remote; cannot push"
  lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *chatwoot/chatwoot*) die "refusing to push: remote '$PRIVATE_REMOTE' points at the public repo ($url)" ;;
    *egytel/egychat*) : ;;
    *) die "remote '$PRIVATE_REMOTE' is not the expected private fork: $url" ;;
  esac
}

# Git objects must stay owned by the service user even though the push runs as root.
fix_git_ownership() {
  [ -n "$CW_USER" ] && chown -R "$CW_USER:$CW_USER" "$APP_DIR/.git" 2>/dev/null || true
}

smoke_test() {
  local host_header origin_code chunk html referenced failures
  log "Smoke test"
  host_header="$(grep -m1 '^FRONTEND_URL=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | sed 's|https\?://||' || true)"
  chunk="$(manifest_chunk)"
  echo "manifest chunk: ${chunk:-unavailable}"

  origin_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000/" || echo 000)"
  [ "$origin_code" = "200" ] || die "origin on :3000 returned $origin_code after the restart"
  echo "origin :3000 -> $origin_code"

  if [ -n "$host_header" ]; then
    html="$(curl -s "http://127.0.0.1:3000/" -H "Host: $host_header" || true)"
  else
    html="$(curl -s "http://127.0.0.1:3000/" || true)"
  fi

  if [ -n "$chunk" ]; then
    case "$html" in
      *"$chunk"*) echo "served HTML references /vite/$chunk" ;;
      *) die "served HTML does not reference the new chunk ($chunk)" ;;
    esac
  fi

  referenced="$(printf '%s' "$html" | grep -oE '/vite/assets/[^"]+' | sort -u || true)"
  failures=0
  for asset in $referenced; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000$asset")"
    [ "$code" = "200" ] || { failures=$((failures + 1)); echo "  FAIL $code $asset"; }
  done
  echo "referenced assets: $(printf '%s\n' "$referenced" | grep -c . || true), failures: $failures"
  [ "$failures" -eq 0 ] || die "some referenced assets are not served"

  if [ -n "$PUBLIC_URL" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/" || echo 000)"
    [ "$code" = "200" ] || die "$PUBLIC_URL returned $code"
    echo "$PUBLIC_URL -> $code"
  else
    echo "PUBLIC_URL not set; verify the public URL from outside the box as well."
  fi
}

print_rollback_recipe() {
  log "Rollback recipe"
  cat <<ROLLBACK
  git reset --hard ${PRE_ALIGN_SHA}              # back to the code as it was
  cp -a ${BACKUP_DIR}/${HOST_SHORT}-env-pre-align-${BACKUP_TS}.bak ${APP_DIR}/.env
  tar xzf ${BACKUP_DIR}/${HOST_SHORT}-public-pre-align-${BACKUP_TS}.tar.gz -C ${APP_DIR}
  pg_restore -d ${POSTGRES_DATABASE:-chatwoot_production} --clean --if-exists \\
    ${BACKUP_DIR}/${HOST_SHORT}-db-pre-align-${BACKUP_TS}.dump   # only if the data changed
  systemctl restart chatwoot.target
  # or simply: ALIGN_ROLLBACK=1 ./deployment/align.sh
ROLLBACK
}

# ==============================================================================
# Rollback mode: restore the newest backup set instead of aligning.
# ==============================================================================
if [ "$ALIGN_ROLLBACK" = "1" ]; then
  [ -d "$APP_DIR/.git" ] || die "not a git repository: $APP_DIR"
  set +e
  latest="$(ls -1t "$BACKUP_DIR"/*-db-pre-align-*.dump 2>/dev/null | head -1)"
  set -e
  [ -n "$latest" ] || die "no backups found in $BACKUP_DIR"
  ts="$(basename "$latest" | sed 's/.*-pre-align-//; s/\.dump$//')"
  host_short="$(basename "$latest" | sed 's/-db-pre-align-.*//')"
  log "Rolling back to backup set $ts ($host_short)"
  git_ rev-parse --verify "pre-align-$ts" >/dev/null 2>&1 || die "git tag pre-align-$ts not found"
  git_ reset --hard "pre-align-$ts"
  cp -a "$BACKUP_DIR/${host_short}-env-pre-align-${ts}.bak" "$APP_DIR/.env" 2>/dev/null \
    && echo ".env restored" || warn ".env backup not found, left as-is"
  tar xzf "$BACKUP_DIR/${host_short}-public-pre-align-${ts}.tar.gz" -C "$APP_DIR" \
    && echo "built assets restored" || warn "asset tarball not found, left as-is"
  if [ "$ALIGN_ROLLBACK_DB" = "1" ]; then
    su - postgres -c "pg_restore -d ${POSTGRES_DATABASE:-chatwoot_production} --clean --if-exists $latest" \
      && echo "database restored" || die "database restore failed"
  else
    warn "database NOT restored (set ALIGN_ROLLBACK_DB=1 to restore it too)"
  fi
  log "Restarting services"
  restart_chatwoot
  log "Rollback to $ts complete."
  exit 0
fi

# ==============================================================================
# Preflight
# ==============================================================================
[ -d "$APP_DIR/.git" ] || die "not a git repository: $APP_DIR"
git_ rev-parse --verify "$PRIVATE_BRANCH" >/dev/null 2>&1 || \
  die "branch '$PRIVATE_BRANCH' not found; fetch it first (git fetch $PRIVATE_REMOTE $PRIVATE_BRANCH)"
if ! git_ diff --quiet || ! git_ diff --cached --quiet; then
  die "working tree is not clean; commit or stash your changes before aligning"
fi
CURRENT_BRANCH="$(git_ branch --show-current)"

if [ "$ALIGN_DRY_RUN" != "1" ] && [ "$CURRENT_BRANCH" != "$PRIVATE_BRANCH" ]; then
  die "on branch '$CURRENT_BRANCH'; align runs on '$PRIVATE_BRANCH' (or set ALIGN_DRY_RUN=1)"
fi
assert_private_remote

DRY_BRANCH=""
cleanup_dry_run() {
  if [ -n "$DRY_BRANCH" ]; then
    git_ merge --abort >/dev/null 2>&1 || true
    git_ checkout "$PRIVATE_BRANCH" >/dev/null 2>&1 || true
    git_ branch -D "$DRY_BRANCH" >/dev/null 2>&1 || true
    echo "dry run: scratch branch $DRY_BRANCH removed, $PRIVATE_BRANCH untouched"
  fi
}
trap cleanup_dry_run EXIT

echo "Aligning branch '$CURRENT_BRANCH' in $APP_DIR"
echo "current version: $(app_version)"

# Ensure a git identity is configured for the merge/branding commits.
if [ -z "$(git_ config user.email)" ]; then
  git_ config user.name "Chatwoot Deploy"
  git_ config user.email "deploy@$(hostname)"
  echo "Configured git identity for commits."
fi

# ==============================================================================
# 0. Backups
# ==============================================================================
if [ "${SKIP_BACKUP:-0}" != "1" ]; then
  log "0/6 Backing up database, built assets and .env"
  mkdir -p "$BACKUP_DIR"
  BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
  HOST_SHORT="$(hostname -s)"
  if [ "$(id -u)" -eq 0 ]; then
    su - postgres -c "pg_dump -Fc ${POSTGRES_DATABASE:-chatwoot_production}" \
      > "$BACKUP_DIR/${HOST_SHORT}-db-pre-align-$BACKUP_TS.dump"
  else
    pg_dump -Fc "${POSTGRES_DATABASE:-chatwoot_production}" \
      > "$BACKUP_DIR/${HOST_SHORT}-db-pre-align-$BACKUP_TS.dump"
  fi
  tar czf "$BACKUP_DIR/${HOST_SHORT}-public-pre-align-$BACKUP_TS.tar.gz" \
    -C "$APP_DIR" public/vite public/packs
  cp -a "$APP_DIR/.env" "$BACKUP_DIR/${HOST_SHORT}-env-pre-align-$BACKUP_TS.bak"
  PRE_ALIGN_SHA="$(git_ rev-parse HEAD)"
  git_ tag "pre-align-$BACKUP_TS" "$PRE_ALIGN_SHA" || true
  echo "Backups in $BACKUP_DIR: db dump, public tarball, .env; git tag pre-align-$BACKUP_TS"
else
  BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
  HOST_SHORT="$(hostname -s)"
  PRE_ALIGN_SHA="$(git_ rev-parse HEAD)"
  echo "SKIP_BACKUP=1: no backups taken."
fi

# ==============================================================================
# 1. Fetch upstream and pick the target
# ==============================================================================
log "1/6 Fetching upstream Chatwoot"
if ! git_ remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git_ remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi
git_ fetch "$UPSTREAM_REMOTE" --tags --prune

if [ -z "$ALIGN_TAG" ]; then
  ALIGN_TAG="$(git_ tag --list 'v*' --sort=-v:refname | head -1)"
  [ -n "$ALIGN_TAG" ] || die "no upstream release tags found; set ALIGN_TAG explicitly"
  echo "No ALIGN_TAG given; using the newest upstream release tag: $ALIGN_TAG"
fi

if [ "$ALIGN_TAG" = "$UPSTREAM_BRANCH" ]; then
  UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
else
  UPSTREAM_REF="$ALIGN_TAG"
fi
git_ rev-parse --verify "$UPSTREAM_REF" >/dev/null 2>&1 || \
  die "target ref '$UPSTREAM_REF' not found (fetched from $UPSTREAM_REMOTE)"

NEW_COMMITS="$(git_ rev-list --count "HEAD..$UPSTREAM_REF" || echo 0)"
BASE="$(git_ merge-base "$PRIVATE_BRANCH" "$UPSTREAM_REF")"
[ -n "$BASE" ] || die "no common ancestor between $PRIVATE_BRANCH and $UPSTREAM_REF"
mapfile -d '' -t BRANDING_FILES < <(git_ diff --name-only -z "$BASE" "$PRIVATE_BRANCH")
echo "target: $UPSTREAM_REF ($NEW_COMMITS commit(s) ahead of our branch)"
echo "our delta vs the merge base: ${#BRANDING_FILES[@]} file(s)"

if [ "$ALIGN_DRY_RUN" = "1" ]; then
  DRY_BRANCH="align-dryrun-$(date +%s)"
  log "Dry run: merging on scratch branch $DRY_BRANCH ($PRIVATE_BRANCH stays untouched)"
  git_ checkout -b "$DRY_BRANCH" >/dev/null
fi

# ==============================================================================
# 2. Merge + resolve + re-apply branding
# ==============================================================================
log "2/6 Merging $UPSTREAM_REF into '$(git_ branch --show-current)'"
if ! git_ merge "$UPSTREAM_REF" --no-edit --no-verify; then
  if git_ ls-files -u | grep -q .; then
    log "Conflicts detected - resolving by policy (deployment/align_conflicts.py)"
    grep -c . <<<"$(git_ diff --name-only --diff-filter=U)" | sed 's/^/conflicted files: /'
    if ! rails_ 'python3 deployment/align_conflicts.py --apply'; then
      warn "the resolver could not handle every conflict. State is preserved:"
      git_ ls-files -u || true
      cat <<'HINT'
  Resolve the reported files by hand (keep upstream's side, re-apply the Hatif brand rule),
  then add a policy for them in deployment/align_conflicts.py, stage them and commit.
  To give up and go back:  git merge --abort
HINT
      exit 3
    fi
  else
    die "git merge failed (not due to conflicts)"
  fi
fi

if git_ ls-files -u | grep -q .; then
  git_ ls-files -u
  die "unresolved merge conflicts remain; resolve them and commit before re-running"
fi

# Stage tracked changes only: never sweep up stray untracked files (.env.bak-* etc.).
git_ add -u
if git_ diff --cached --quiet; then
  echo "Merge produced no changes to commit."
else
  if git_ rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git_ commit --no-verify -m "Merge upstream $ALIGN_TAG into $PRIVATE_BRANCH (Hatif white-label preserved)"
  else
    git_ commit --no-verify -m "$BRAND_COMMIT_MSG"
  fi
fi

log "Re-applying the brand rule to dashboard strings upstream added"
rails_ 'python3 deployment/brand_sweep.py'
rails_ 'python3 deployment/brand_sweep.py --apply'
if ! git_ diff --quiet; then
  git_ add -u -- app/javascript/dashboard/i18n/locale/en
  git_ commit --no-verify -m "$BRAND_SWEEP_MSG"
else
  echo "No new Chatwoot strings in the dashboard locale."
fi

# ==============================================================================
# 3. Gate: the fork's customizations must still be present
# ==============================================================================
log "3/6 Verifying the Hatif customizations survived"
rails_ "bash deployment/verify_customizations.sh '$UPSTREAM_REF'" || \
  die "customization verification failed - nothing was installed, migrated or restarted"

if [ "$ALIGN_DRY_RUN" = "1" ]; then
  log "Dry run result"
  git_ diff --stat "$PRE_ALIGN_SHA..HEAD" | tail -20
  echo
  echo "commits that a real run would keep:"
  git_ log --oneline "$PRE_ALIGN_SHA..HEAD" || true
  echo
  echo "dry run finished: $PRIVATE_BRANCH is unchanged, no dependency install, no migration,"
  echo "no front-end rebuild and no service restart happened."
  exit 0
fi

# ==============================================================================
# 4. Dependencies + migrations
# ==============================================================================
log "4/6 Installing Ruby and JS dependencies"
rails_ 'bundle install'
rails_ 'pnpm install'

log "5/6 Running database migrations"
rails_ 'RAILS_ENV=production POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:migrate'

log "Rebuilding the front end (so branding takes effect)"
# DISABLED (validated 2026-09-27): assets:precompile also regenerates the sprockets
# public/assets tree this fork deliberately pruned, and it bundles the widget SDK.
# rails_ 'RAILS_ENV=production NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider" bundle exec rails assets:precompile'
rails_ 'pnpm run build:sdk'
rails_ 'RAILS_ENV=production NODE_OPTIONS="--max-old-space-size=4096" bin/vite build'

# ==============================================================================
# 5. Restart + smoke test
# ==============================================================================
log "6/6 Restarting services"
restart_chatwoot
sleep 25
smoke_test

# ==============================================================================
# 6. Push the private branch
# ==============================================================================
if [ "$ALIGN_PUSH" = "1" ]; then
  log "Pushing $PRIVATE_BRANCH to '$PRIVATE_REMOTE' (private fork only)"
  assert_private_remote
  HOME="${HOME:-/root}" git -C "$APP_DIR" push "$PRIVATE_REMOTE" "$PRIVATE_BRANCH:$PRIVATE_BRANCH"
  fix_git_ownership
  git_ fetch "$PRIVATE_REMOTE" "$PRIVATE_BRANCH" >/dev/null 2>&1 || true
  echo "remote $PRIVATE_REMOTE/$PRIVATE_BRANCH: $(git_ rev-parse "$PRIVATE_REMOTE/$PRIVATE_BRANCH" 2>/dev/null || echo unknown)"
  echo "local  $PRIVATE_BRANCH: $(git_ rev-parse "$PRIVATE_BRANCH")"
else
  echo "ALIGN_PUSH=0: skipping the push (nothing sent to $PRIVATE_REMOTE)"
fi

log "Align complete: upstream $UPSTREAM_REF + Hatif branding (version $(app_version))."
echo "Services restarted and smoke-tested; the public URL is $PUBLIC_URL${PUBLIC_URL:+ - }"
echo "check it from outside the box (the origin cannot reach its own public IP)."
print_rollback_recipe
