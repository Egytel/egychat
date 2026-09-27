#!/bin/bash
# Verify the Hatif customizations survived an upstream align.
#
# Every check is a fact about the tree, and any failure is fatal: align.sh runs this
# BEFORE it installs dependencies, migrates or restarts anything, so a broken tree never
# reaches the running services.
#
# Usage: verify_customizations.sh <target-ref>       (e.g. v4.18.0)

set -uo pipefail
TARGET="${1:-}"
APP_DIR="${CHATWOOT_DIR:-/home/chatwoot/chatwoot}"
cd "$APP_DIR" || exit 2

FAILURES=0
PASSES=0

ok()   { PASSES=$((PASSES + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# grep_present <file> <pattern> <label>
grep_present() {
  if [ ! -f "$1" ]; then fail "$3 (missing file: $1)"; return; fi
  if grep -q -- "$2" "$1"; then ok "$3"; else fail "$3 (no match for '$2' in $1)"; fi
}

# file_differs_from_upstream <path> <label>  -- the fork replaced this upstream file
file_differs_from_upstream() {
  if [ -z "$TARGET" ]; then ok "$2 (no target ref, skipped comparison)"; return; fi
  if git cat-file -e "$TARGET:$1" 2>/dev/null; then
    if git diff --quiet "$TARGET" -- "$1"; then
      fail "$2 (identical to $TARGET - the fork's version was overwritten)"
    else
      ok "$2"
    fi
  else
    ok "$2 (not in $TARGET, fork-only file)"
  fi
}

echo "== WhatsApp: webhook-managed-externally patch =="
grep_present app/services/whatsapp/webhook_setup_service.rb 'include Whatsapp::WebhookManagedExternally' "webhook_setup_service includes the managed-externally module"
grep_present app/services/whatsapp/webhook_setup_service.rb 'subscribe_app_to_waba' "webhook_setup_service still subscribes the WABA"
grep_present app/services/whatsapp/health_service.rb 'include Whatsapp::WebhookManagedExternally' "health_service includes the managed-externally module"
grep_present app/services/whatsapp/health_service.rb 'webhook_managed_externally' "health_service reports webhook_managed_externally"
grep_present app/services/whatsapp/webhook_managed_externally.rb 'webhook_managed_externally' "webhook_managed_externally.rb helper present"
grep_present app/javascript/dashboard/routes/dashboard/settings/inbox/components/AccountHealth.vue 'webhook_managed_externally' "AccountHealth.vue handles the external webhook state"
grep_present app/javascript/dashboard/i18n/locale/en/inboxMgmt.json 'MANAGED_EXTERNALLY' "AccountHealth locale keys present"

echo "== Super Admin config plumbing =="
grep_present config/installation_config.yml 'WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY' "WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY defined in installation_config.yml"
grep_present app/controllers/super_admin/app_configs_controller.rb 'WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY' "WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY editable from Super Admin"

echo "== Branding =="
file_differs_from_upstream public/brand-assets/logo.svg "Hatif logo.svg differs from upstream"
file_differs_from_upstream public/brand-assets/logo_dark.svg "Hatif logo_dark.svg differs from upstream"
file_differs_from_upstream public/favicon-32x32.png "favicon-32x32.png is the Hatif mark"
file_differs_from_upstream public/apple-icon-180x180.png "apple-icon-180x180.png is the Hatif mark"
grep_present public/manifest.json 'Hatif' "manifest.json names Hatif"
grep_present app/views/installation/onboarding/index.html.erb 'SuperAdmin | Hatif' "onboarding page title is branded"
grep_present app/views/super_admin/devise/sessions/new.html.erb 'SuperAdmin | Hatif' "super admin sign-in title is branded"
grep_present app/views/installation/onboarding/index.html.erb 'Welcome to Hatif' "onboarding greeting is branded"

echo "== No user-facing 'Chatwoot' left in the dashboard locale =="
if [ -f deployment/brand_sweep.py ]; then
  sweep="$(python3 deployment/brand_sweep.py | tail -1)"
  case "$sweep" in
    *"total: 0"*) ok "brand sweep reports 0 remaining strings" ;;
    *) fail "brand sweep reports remaining strings: $sweep" ;;
  esac
else
  fail "deployment/brand_sweep.py is missing"
fi

echo "== Version =="
case "$TARGET" in
  v[0-9]*) : ;;
  *) TARGET="" ;;   # only release tags carry a version worth asserting
esac
if [ -n "$TARGET" ]; then
  want="${TARGET#v}"
  have="$(grep -m1 "version:" config/app.yml | tr -d " 'version:")"
  if [ "$have" = "$want" ]; then ok "config/app.yml version is $have"; else fail "config/app.yml is $have, expected $want"; fi
  pkg="$(grep -m1 '"version"' package.json | cut -d'"' -f4)"
  if [ "$pkg" = "$want" ]; then ok "package.json version is $pkg"; else fail "package.json is $pkg, expected $want"; fi
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '\033[1;31m%s check(s) FAILED, %s passed - do not continue\033[0m\n' "$FAILURES" "$PASSES"
  exit 1
fi
printf '\033[1;32mall %s customization check(s) passed\033[0m\n' "$PASSES"
