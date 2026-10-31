#!/usr/bin/env bash
# Move the CI branch onto the newest Julia release, each branch of .github/features.txt onto
# its base, and open pull requests onto the branch they were built on; then rebuild main as
# the CI branch plus one merge per listed branch. PUSH=0 builds without pushing.
set -euo pipefail
ci=1.13/fork/ci
fail() { echo "::error::$*"; exit 1; }
push() { # branch, expected remote tip, new tip
    if [ "${PUSH:-1}" = 1 ]; then git push -q --force-with-lease="$1:$2" origin "$3:refs/heads/$1"; fi
}

git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git fetch -q --tags https://github.com/JuliaLang/julia.git

# main records what it was built from: its first non-merge ancestor is the CI tip it used,
# and the second parent of each "assemble: merge X" is the tip of X it used.
declare -A prev tip base
main=$(git rev-parse origin/main)
prev[$ci]=$(git rev-list --first-parent --no-merges -1 "$main")
while read -r _ _ side _ _ name; do
    if [ -z "${prev[$name]:-}" ]; then prev[$name]=$side; fi
done < <(git log --first-parent --merges --format='%H %P %s' "$main" | grep ' assemble: merge ' || true)

order=()
while read -r branch parent _; do
    if [ -z "$branch" ] || [ "${branch:0:1}" = '#' ]; then continue; fi
    order+=("$branch")
    base[$branch]=${parent:-$ci}
done < <(git show "origin/$ci:.github/features.txt")

old=$(git rev-parse "origin/$ci")
latest=$(git tag -l 'v*' | grep -xE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
release=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' "$old")
tip[$ci]=$old
if [ "$release" != "$latest" ]; then
    git checkout -q --detach "$old"
    if ! git rebase -q --onto "$latest" "$release"; then git rebase --abort; fail "$ci conflicts with $latest"; fi
    tip[$ci]=$(git rev-parse HEAD)
    push "$ci" "$old" HEAD
fi

# Put branch $1 (at $2) on the current tip of $3. Returns 1 if $2 is built on neither tip of $3.
restack() {
    local branch=$1 old=$2 onto=${tip[$3]} from=${prev[$3]:-}
    if git merge-base --is-ancestor "$onto" "$old"; then tip[$branch]=$old; return 0; fi
    if [ -z "$from" ] || ! git merge-base --is-ancestor "$from" "$old"; then return 1; fi
    git checkout -q --detach "$old"
    if ! git rebase -q --onto "$onto" "$from"; then git rebase --abort; fail "$branch conflicts with $3"; fi
    tip[$branch]=$(git rev-parse HEAD)
    push "$branch" "$old" HEAD
}

for branch in "${order[@]}"; do
    if [ -z "${tip[${base[$branch]}]:-}" ]; then fail "list ${base[$branch]} above $branch in .github/features.txt"; fi
    current=$(git rev-parse --verify -q "origin/$branch") || fail "$branch is listed but does not exist"
    if ! restack "$branch" "$current" "${base[$branch]}"; then
        fail "$branch is not built on ${base[$branch]}; rebase it by hand"
    fi
done

git checkout -q --detach "${tip[$ci]}"
merged=()
for branch in "${order[@]}"; do
    if ! git merge -q --no-ff -m "assemble: merge $branch" "${tip[$branch]}"; then
        git merge --abort
        for other in "${merged[@]}"; do
            if ! git merge-tree --write-tree --quiet "${tip[$other]}" "${tip[$branch]}" >/dev/null; then
                fail "$branch conflicts with $other"
            fi
        done
        fail "$branch conflicts with the merge of ${merged[*]}"
    fi
    merged+=("$branch")
done
# A rebuilt merge has a new hash, so compare the tree and what each merge took in.
sources() { git rev-parse "$1^{tree}"; git rev-list --first-parent --no-merges -1 "$1"; git log --first-parent --merges --format=%P "$1" | cut -d' ' -f2; }
if [ "$(sources HEAD)" != "$(sources "$main")" ]; then
    push main "$main" HEAD
fi

# Open pull requests into main: move each onto the nearest listed branch, or the CI branch, it was built on.
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    stale=()
    candidates=()
    for (( i=${#order[@]}-1; i>=0; i-- )); do candidates+=("${order[i]}"); done
    candidates+=("$ci")
    for head in $(gh pr list --repo "$GITHUB_REPOSITORY" --base main --state open --json headRefName,isCrossRepository --jq '.[] | select(.isCrossRepository | not) | .headRefName'); do
        if [ -n "${base[$head]:-}" ]; then continue; fi
        old=$(git rev-parse "origin/$head")
        moved=0
        for candidate in "${candidates[@]}"; do
            if restack "$head" "$old" "$candidate"; then moved=1; break; fi
        done
        if [ $moved = 0 ]; then stale+=("$head"); fi
    done
    if [ ${#stale[@]} -gt 0 ]; then fail "Rebase these pull request branches onto $ci or a listed branch by hand: ${stale[*]}"; fi
fi
