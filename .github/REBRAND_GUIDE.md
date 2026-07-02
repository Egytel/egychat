# EgyChat Rebrand Guide
<!-- MACHINE-READABLE: This file is consumed by the Chatwoot Rebrand Guide agent -->
<!-- Run: @rebrand-guide to activate the agent that follows this guide -->

> **Current upstream version:** v4.14.2  
> **Private branch:** `private/main`  
> **Upstream remote:** `upstream` (https://github.com/chatwoot/chatwoot.git) — **push disabled**  
> **Private remote:** `origin` (git@github.com:Egytel/egychat.git)

---

## Git Remote Structure

```
upstream  https://github.com/chatwoot/chatwoot.git  (fetch — READ ONLY)
upstream  no_push                                     (push — DISABLED)
origin    git@github.com:Egytel/egychat.git           (fetch)
origin    git@github.com:Egytel/egychat.git           (push — YOUR REPO)
```

### Verify remotes are correct
```bash
git remote -v
# Should show upstream with no_push and origin pointing to Egytel/egychat
```

### Pull upstream updates (run whenever Chatwoot releases a new version)
```bash
git fetch upstream
git checkout private/main
git rebase upstream/master
# Resolve any conflicts (see Conflict Resolution section below)
git push origin private/main --force-with-lease
git tag sync/$(cat VERSION_CW) upstream/$(git describe --tags upstream/master 2>/dev/null || echo master)
```

---

## Brand Replacement Map

Replace every occurrence of `Chatwoot` / `chatwoot` with your brand values.
This table lists **every file that must be touched** — nothing more.

| # | File | Lines / Keys | What to replace | Conflict risk |
|---|------|-------------|-----------------|---------------|
| 1 | `config/installation_config.yml` | `INSTALLATION_NAME`, `BRAND_NAME`, `BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL`, `DISPLAY_MANIFEST` | Values → your brand | 🟢 Very Low |
| 2 | `enterprise/config/premium_installation_config.yml` | Same keys as above | Values → your brand | 🟢 Very Low |
| 3 | `public/brand-assets/logo.svg` | Entire file | Replace with your light-mode SVG logo | 🟢 Very Low |
| 4 | `public/brand-assets/logo_dark.svg` | Entire file | Replace with your dark-mode SVG logo | 🟢 Very Low |
| 5 | `public/brand-assets/logo_thumbnail.svg` | Entire file | Replace with your 512×512 favicon SVG | 🟢 Very Low |
| 6 | `public/manifest.json` | `name`, `short_name`, `background_color`, `theme_color` | Values → your brand | 🟢 Very Low |
| 7 | `public/favicon.ico` | Entire file | Replace with your favicon | 🟢 Very Low |
| 8 | `public/favicon-*.png` (7 files) | Entire files | Replace with your favicon PNGs | 🟢 Very Low |
| 9 | `public/android-icon-*.png` (6 files) | Entire files | Replace with your Android icons | 🟢 Very Low |
| 10 | `public/apple-icon*.png` (11 files) | Entire files | Replace with your Apple touch icons | 🟢 Very Low |
| 11 | `app/javascript/dashboard/i18n/locale/en/login.json` | line 3: `TITLE` | `"Login to Chatwoot"` → `"Login to EgyChat"` | 🟡 Low |
| 12 | `app/javascript/dashboard/i18n/locale/en/signup.json` | line 4: `GET_STARTED` | `"Get started with Chatwoot"` → `"Get started with EgyChat"` | 🟡 Low |
| 13 | `app/javascript/dashboard/i18n/locale/en/auditLogs.json` | lines 9, 13 | `Chatwoot System` → `EgyChat System` | 🟡 Low |
| 14 | `app/javascript/dashboard/i18n/locale/en/generalSettings.json` | lines 126, 128, 129, 130 | `Chatwoot` → `EgyChat` | 🟡 Low |
| 15 | `app/javascript/dashboard/i18n/locale/en/helpCenter.json` | line 787: `PLACEHOLDER` | `"User Guide \| Chatwoot"` → `"User Guide \| EgyChat"` | 🟡 Low |
| 16 | `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json` | lines 19, 45, 454, 516, 520, 1169 | `Chatwoot` → `EgyChat` | 🟡 Low |
| 17 | `app/javascript/dashboard/i18n/locale/en/integrations.json` | lines 20, 47, 82, 130, 137, 239 | `Chatwoot` → `EgyChat` | 🟡 Low |
| 18 | `app/javascript/dashboard/i18n/locale/en/labelsMgmt.json` | line 53: `POWERED_BY` | `"Chatwoot AI"` → `"EgyChat AI"` | 🟡 Low |
| 19 | `app/javascript/dashboard/i18n/locale/en/mfa.json` | `CONTACT_DESC_CLOUD` | `"Chatwoot support"` → `"EgyChat support"` | 🟡 Low |
| 20 | `app/javascript/dashboard/i18n/locale/en/resetPassword.json` | line 4: `DESCRIPTION` | `"log in to Chatwoot"` → `"log in to EgyChat"` | 🟡 Low |
| 21 | `app/javascript/dashboard/i18n/locale/en/settings.json` | lines 40, 614 | `Chatwoot` → `EgyChat` | 🟡 Low |
| 22 | `app/javascript/dashboard/i18n/locale/en/yearInReview.json` | lines 51, 52 | `Chatwoot` → `EgyChat` | 🟡 Low |
| 23 | `app/javascript/dashboard/i18n/locale/en/conversation.json` | line 286: `NATIVE_APP_ADVISORY` | `"Reply from Chatwoot"` → `"Reply from EgyChat"` | 🟡 Low |
| 24 | `app/javascript/widget/i18n/locale/en.json` | line 60: `POWERED_BY` | `"Powered by Chatwoot"` → `"Powered by EgyChat"` | 🟡 Low |
| 25 | `config/locales/en.yml` | lines 350, 351, 356, 359 | `Chatwoot` → `EgyChat` in integration descriptions | 🟡 Low |
| 26 | `app/views/layouts/mailer/base.liquid` | line 95 | Fallback `'Chatwoot'` → `'EgyChat'` | 🔴 Medium |
| 27 | `app/json` | lines 2-6 | `name`, `description`, `website`, `repository`, `logo` | 🟢 Very Low |

> **Do NOT touch:** `package.json` `@chatwoot/` package names — those are npm dependency identifiers, not brand strings.  
> **Do NOT touch:** Any locale file other than `en/` — community-translated, will conflict on upstream sync.

---

## Step-by-Step Execution

### Step 1 — Config files (lowest risk, do first)

Edit `config/installation_config.yml`:
```yaml
- name: INSTALLATION_NAME
  value: 'Hatif Chat'          # ← was 'Chatwoot'
- name: BRAND_NAME
  value: 'Hatif Chat'          # ← was 'Chatwoot'
- name: BRAND_URL
  value: 'https://egytelecoms.com'   # ← was 'https://www.chatwoot.com'
- name: WIDGET_BRAND_URL
  value: 'https://egytelecoms.com'   # ← was 'https://www.chatwoot.com'
- name: TERMS_URL
  value: 'https://egytelecoms.com/terms'  # ← was chatwoot.com URL
- name: PRIVACY_URL
  value: 'https://egytelecoms.com/privacy' # ← was chatwoot.com URL
- name: DISPLAY_MANIFEST
  value: false              # ← set false to hide Chatwoot metadata
```

Mirror the **exact same changes** in `enterprise/config/premium_installation_config.yml`.

After editing, sync to the database:
```bash
bundle exec rails installation_config:sync
```

### Step 2 — Logo / SVG assets

Drop your files into `public/brand-assets/` keeping the **exact same filenames**:
- `logo.svg` — light mode, used on dashboard and login page
- `logo_dark.svg` — dark mode variant
- `logo_thumbnail.svg` — favicon / PWA icon (512×512 recommended)

### Step 3 — PWA Manifest

Edit `public/manifest.json`:
```json
{
  "name": "EgyChat",
  "short_name": "EgyChat",
  "background_color": "#YOUR_COLOR",
  "theme_color": "#YOUR_COLOR"
}
```

### Step 4 — Favicon and touch icons

Replace these files in `public/` with your own (keep identical filenames):
```
favicon.ico
favicon-16x16.png
favicon-32x32.png
favicon-96x96.png
favicon-512x512.png
favicon-badge-16x16.png
favicon-badge-32x32.png
favicon-badge-96x96.png
apple-icon.png
apple-icon-precomposed.png
apple-touch-icon.png
apple-touch-icon-precomposed.png
apple-icon-57x57.png  apple-icon-60x60.png  apple-icon-72x72.png
apple-icon-76x76.png  apple-icon-114x114.png apple-icon-120x120.png
apple-icon-144x144.png apple-icon-152x152.png apple-icon-180x180.png
android-icon-36x36.png  android-icon-48x48.png  android-icon-72x72.png
android-icon-96x96.png  android-icon-144x144.png android-icon-192x192.png
```

### Step 5 — Frontend i18n (en/ locale files)

Run the automated replacement (safe — only touches `en/` files):
```bash
cd app/javascript/dashboard/i18n/locale/en
# Preview changes first:
grep -rn 'Chatwoot' . --include="*.json"
# Apply:
find . -name "*.json" -exec sed -i 's/Chatwoot/EgyChat/g' {} +
# Then manually review each changed file to catch context-sensitive strings
```

Also update the widget locale:
```bash
sed -i 's/Powered by Chatwoot/Powered by EgyChat/g' \
  ../../../widget/i18n/locale/en.json
```

### Step 6 — Backend i18n

```bash
grep -n 'Chatwoot' config/locales/en.yml
# Edit manually — only the 4 integration description lines, not keys
```

### Step 7 — Mailer fallback (base.liquid)

In `app/views/layouts/mailer/base.liquid` line 95, change the hardcoded fallback:
```liquid
{%- assign brand_name = 'EgyChat' -%}   {# was 'Chatwoot' #}
```
> This is a fallback-only string. When `BRAND_NAME` is set in config (Step 1), this line is never reached in production.

### Step 8 — Commit with brand: prefix

```bash
git add config/installation_config.yml \
        enterprise/config/premium_installation_config.yml \
        public/brand-assets/ \
        public/manifest.json \
        public/favicon* public/apple-* public/android-* \
        app/javascript/dashboard/i18n/locale/en/ \
        app/javascript/widget/i18n/locale/en.json \
        config/locales/en.yml \
        app/views/layouts/mailer/base.liquid

git commit -m "brand: complete EgyChat rebrand from Chatwoot v4.14.2"
git tag brand/v1.0
git push origin private/main
```

---

## Pulling Upstream Updates (Ongoing)

```bash
# 1. Fetch new upstream commits
git fetch upstream

# 2. Rebase your brand commits on top
git checkout private/main
git rebase upstream/master

# 3. If conflicts occur in brand-safe files (config/installation_config.yml etc.):
#    Accept upstream version, then re-apply your values on top
git checkout --ours config/installation_config.yml
git add config/installation_config.yml
git rebase --continue

# 4. Push
git push origin private/main --force-with-lease

# 5. Tag the sync point
git tag sync/$(cat VERSION_CW)
```

### Files Most Likely to Conflict on Rebase

| File | How to Resolve |
|------|---------------|
| `config/installation_config.yml` | Accept upstream, re-apply your values from this guide |
| `app/javascript/dashboard/i18n/locale/en/*.json` | Accept upstream new keys, re-apply your brand-name replacements |
| `public/manifest.json` | Accept upstream structure, keep your name/color values |
| `app/views/layouts/mailer/base.liquid` | Accept upstream structure, keep your fallback name |

### Files That Will NEVER Conflict (you own them fully)
- `public/brand-assets/logo*.svg` — not tracked upstream
- `public/favicon.ico`, `*.png` icons — upstream never changes these

---

## Quick Audit Commands

```bash
# Check remaining Chatwoot brand strings (run after each step to verify completion)
grep -rn 'Chatwoot' \
  config/installation_config.yml \
  enterprise/config/premium_installation_config.yml \
  public/manifest.json \
  app/javascript/dashboard/i18n/locale/en/ \
  app/javascript/widget/i18n/locale/en.json \
  config/locales/en.yml \
  app/views/layouts/mailer/base.liquid

# View only your brand commits
git log --oneline --grep="^brand:"

# Verify remote safety (upstream should show no_push)
git remote -v
```

---

## Checklist

- [ ] `git remote -v` shows `upstream` → `no_push`, `origin` → `git@github.com:Egytel/egychat.git`
- [ ] On branch `private/main`
- [ ] **Step 1** — `config/installation_config.yml` values updated
- [ ] **Step 1** — `enterprise/config/premium_installation_config.yml` values updated
- [ ] **Step 1** — `bundle exec rails installation_config:sync` run on live instance
- [ ] **Step 2** — `public/brand-assets/logo.svg` replaced
- [ ] **Step 2** — `public/brand-assets/logo_dark.svg` replaced
- [ ] **Step 2** — `public/brand-assets/logo_thumbnail.svg` replaced
- [ ] **Step 3** — `public/manifest.json` `name` and `short_name` updated
- [ ] **Step 4** — All `public/favicon*.png` replaced
- [ ] **Step 4** — All `public/apple-icon*.png` replaced
- [ ] **Step 4** — All `public/android-icon*.png` replaced
- [ ] **Step 4** — `public/favicon.ico` replaced
- [ ] **Step 5** — All `en/` locale JSON files updated
- [ ] **Step 5** — `app/javascript/widget/i18n/locale/en.json` `POWERED_BY` updated
- [ ] **Step 6** — `config/locales/en.yml` integration descriptions updated
- [ ] **Step 7** — `app/views/layouts/mailer/base.liquid` fallback name updated
- [ ] **Step 8** — All changes committed with `brand:` prefix and tagged `brand/v1.0`
- [ ] **Step 8** — Pushed to `origin private/main`
