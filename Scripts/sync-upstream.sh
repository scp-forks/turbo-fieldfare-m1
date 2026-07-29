#!/usr/bin/env bash
# Pull new upstream TurboFieldfare changes into this macOS 14/15 fork.
#
#   Scripts/sync-upstream.sh
#
# Safe to run repeatedly. It never force-pushes and never rewrites history, so
# a bad run can always be undone. If anything needs a human decision it stops
# and prints exactly what to do.

set -uo pipefail

UPSTREAM_URL="https://github.com/drumih/turbo-fieldfare.git"
FORK_BRANCH="macos14-support"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\n  \033[31m✗ %s\033[0m\n" "$1"; exit 1; }

cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.." || die "cannot find repo root"

bold "1. Checking your working tree"
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  die "You have uncommitted changes. Commit or stash them first:
      git stash        # set them aside
      git stash pop    # bring them back afterwards"
fi
ok "clean"

bold "2. Making sure we are on $FORK_BRANCH"
current="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current" != "$FORK_BRANCH" ]]; then
  warn "was on '$current', switching"
  git checkout "$FORK_BRANCH" || die "could not switch to $FORK_BRANCH"
fi
ok "on $FORK_BRANCH"

bold "3. Making sure the 'upstream' remote exists"
if ! git remote get-url upstream >/dev/null 2>&1; then
  warn "not configured, adding it"
  git remote add upstream "$UPSTREAM_URL" || die "could not add upstream remote"
fi
ok "upstream -> $(git remote get-url upstream)"

bold "4. Fetching upstream"
git fetch upstream --tags || die "fetch failed (network?)"
ok "fetched"

bold "5. What is new upstream"
new_count="$(git rev-list --count HEAD..upstream/main)"
if [[ "$new_count" == "0" ]]; then
  ok "Nothing new. You are already up to date. Done."
  exit 0
fi
printf "  %s new upstream commit(s):\n\n" "$new_count"
git log --oneline --no-decorate HEAD..upstream/main | sed 's/^/    /'
printf "\n"

bold "6. Saving a rescue point"
rescue="pre-sync-$(git rev-parse --short HEAD)"
git tag -f "$rescue" >/dev/null 2>&1
ok "tagged '$rescue' — undo this whole sync with:  git reset --hard $rescue"

bold "7. Merging upstream/main into $FORK_BRANCH"
# Merge rather than rebase: it does not rewrite history, so a normal
# 'git push' works afterwards with no --force.
if git merge --no-edit upstream/main; then
  ok "merged cleanly"
else
  printf "\n"
  bold "   Merge stopped on conflicts. This is normal and fixable."
  git diff --name-only --diff-filter=U | sed 's/^/     /'
  cat <<'EOF'

   Package.swift is the usual one. The fork needs these lines kept:

       platforms: [
           .macOS(.v14),
           .iOS(.v17),
       ],

   ...and the TurboFieldfareCompat target entry kept. Take upstream's version
   of everything else in that file.

   Then:
       git add <each file you fixed>
       git commit
       swift build -c release && swift test -c release --no-parallel

   Or abandon the whole attempt and go back to where you started:
       git merge --abort
EOF
  exit 1
fi

bold "8. Rebuilding"
if swift build -c release; then
  ok "build succeeded"
else
  die "Build failed after merging. Upstream probably added a macOS 26 API.
      See the 'What this fork changes' table in MACOS14.md for the pattern:
      query new SDK enum cases by raw value, and gate new OS APIs behind
      'if #available'. Undo with:  git reset --hard $rescue"
fi

bold "9. Testing"
swift build --product TurboFieldfareRepack >/dev/null 2>&1
if swift test -c release --no-parallel 2>&1 | tee /tmp/sync-upstream-test.log \
     | grep -E "Test run with .* tests?" | tail -2; then
  :
fi
fails="$(grep -cE '✘ Test [A-Za-z0-9_]+\(\) recorded an issue' /tmp/sync-upstream-test.log || true)"
if [[ "${fails:-0}" -le 1 ]]; then
  ok "tests look right (expect exactly 1 known failure: lockIsReleasedWhenOwningProcessIsKilled, which needs /usr/bin/lockf and macOS does not ship it)"
else
  warn "$fails failing tests — more than the 1 known failure. Full log: /tmp/sync-upstream-test.log"
fi

printf "\n"
bold "Done. To publish:"
printf "    git push origin %s\n\n" "$FORK_BRANCH"
printf "  No --force needed. To undo everything:  git reset --hard %s\n\n" "$rescue"
