#!/usr/bin/env bash
# Move the CI branch onto the newest Julia release (its feature branches follow, being its
# descendants), then rebuild main as one merge of the CI branch and every branch listed in
# .github/features.txt. Run from the repository root. PUSH=0 builds without pushing;
# REMOTE names the fork remote (default origin).
set -euo pipefail
remote=${REMOTE:-origin}
ci=1.13/fork/ci
fail() { echo "::error::$*"; exit 1; }
rev() { jj log --no-graph -r "$1" -T 'commit_id ++ "\n"'; }

jj git remote add upstream https://github.com/JuliaLang/julia.git 2>/dev/null || true
jj git fetch --remote "$remote"
jj git fetch --remote upstream --tag 'v*'

# features.txt lines are "branch [base]"; stacking lives in history, so the base is not read.
mapfile -t features < <(jj file show -r "\"$ci\"@$remote" .github/features.txt | rg -v '^\s*(#|$)' | cut -d' ' -f1)
for name in "$ci" "${features[@]}" main; do
    jj bookmark track "exact:$name" --remote "$remote" 2>/dev/null || true
done
CI="\"$ci\""

latest=$(jj tag list -T 'name ++ "\n"' | rg -x 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
release=$(jj log --no-graph -r "heads(::$CI & tags(regex:'^v[0-9]+\.[0-9]+\.[0-9]+\$'))" -T 'tags.map(|t| t.name()).join("\n") ++ "\n"' | rg -x 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
if [ "$release" != "$latest" ]; then
    stack="roots($release..$CI)"
    # The rebase moves every descendant of the stack; only the CI branch, the listed branches and main may sit there.
    allowed="::($CI | main"
    for name in "${features[@]}"; do allowed+=" | \"$name\""; done
    allowed+=")"
    stray=$(rev "descendants($stack) ~ $allowed")
    if [ -n "$stray" ]; then fail "commits built on $ci would move with it: $stray"; fi
    jj rebase -s "$stack" -d "$latest"
fi

# A feature that is not yet on the CI branch moves onto it, together with whatever it carries.
for name in "${features[@]}"; do
    if [ -z "$(rev "\"$name\" & $CI::")" ]; then jj rebase -b "\"$name\"" -d "$CI"; fi
done
conflicted=$(jj log --no-graph -r 'conflicts()' -T 'bookmarks ++ " " ++ description.first_line() ++ "\n"')
if [ -n "$conflicted" ]; then fail "conflicts after restacking: $conflicted"; fi

parents=("$CI")
for name in "${features[@]}"; do parents+=("\"$name\""); done
wanted=$(rev "$(IFS='|'; echo "${parents[*]}")" | sort)
if [ "$wanted" != "$(rev 'main-' | sort)" ]; then
    jj new "${parents[@]}" -m "assemble: main"
    jj bookmark set main --allow-backwards -r @
fi

if [ "${PUSH:-1}" = 1 ]; then
    bookmarks=(--bookmark "$ci" --bookmark main)
    for name in "${features[@]}"; do bookmarks+=(--bookmark "$name"); done
    jj git push --remote "$remote" "${bookmarks[@]}"
fi
