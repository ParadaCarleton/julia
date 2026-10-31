`main` is a jj megamerge: one merge commit whose parents are `1.13/fork/ci` and each branch in `features.txt`.

- Edit a feature: `jj edit <feature>`, change, `jj new main`. Descendants, including the megamerge, rebase themselves.
- Move a megamerge fix into its feature: `jj absorb`.
- New Julia release: check that `jj log -r '"1.13/fork/ci"::'` lists only our commits, then `jj rebase -s 'roots(<old tag>..1.13/fork/ci)' -d <new tag>`. Conflicts stay in the commits; fix with `jj resolve`.
- Push: `jj git push --bookmark main --bookmark <feature>...`. jj refuses conflicted commits.

`assemble-jj.sh` does the release step and rebuilds the merge in CI.
