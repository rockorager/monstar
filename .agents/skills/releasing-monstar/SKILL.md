---
name: releasing-monstar
description: Prepares and cuts Monstar releases with checked-in release notes and `just release`. Use when drafting release notes, cutting a release, creating a version tag, or checking release readiness.
---

# Releasing Monstar

A Monstar release is a signed `vX.Y.Z` tag on a `release: X.Y.Z` commit that sets `.version` in `build.zig.zon`. `just release [X.Y.Z]` makes that commit on top of `origin/main`, tags it, and pushes both atomically; the Release workflow then builds the tag, publishes the GitHub release with its tarballs and `SHA256SUMS`, and updates the AUR packages. Never edit the version in `build.zig.zon` by hand.

## Release contract

- Versions are `X.Y.Z` and tags `vX.Y.Z`. `just release` with no version releases the newest tag's next patch.
- Notes live at `docs/releases/X.Y.Z.md` and are committed to `main` before the release. The workflow publishes that file as the release description; without it, the release lists the commits since the previous tag.
- Development builds report `X.Y.(Z+1)-dev.<distance>+g<sha>` after `vX.Y.Z`, or the version in `build.zig.zon` when it is newer. An exact clean tag reports `X.Y.Z`.

## Approvals

- `just release` pushes to `main` and pushes a tag, so run it only after the user explicitly approves releasing that version. Approval to write notes does not cover releasing.
- Pushing the notes commit is a separate push and needs its own approval.
- Never move, replace, or delete a published tag without explicit approval and a clear explanation of the consequences.

## 1. Establish the release

1. Confirm the version, or that the next patch is intended. Choose minor for new features and patch for fixes alone.
2. Fetch, then find the previous release with `git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main`.
3. Read the commits and diffs since that tag. Describe user-visible outcomes, not every commit subject or internal refactor.

## 2. Write the release notes

Create `docs/releases/X.Y.Z.md` with this shape:

```markdown
# Monstar X.Y.Z

Released YYYY-MM-DD.

## Highlights

- The most important user-visible changes.

## Added

- New capabilities.

## Changed

- Meaningful behavior or compatibility changes.

## Fixed

- User-visible defects that were corrected.
```

Keep only sections that have content. Add `## Upgrade notes` when users must take action. The notes stand alone when read from a source archive or another forge, so keep them free of compare links, forge boilerplate, and publishing instructions. Verify every claim against the code or documentation, and call out breaking changes, migrations, known limitations, and changed requirements.

Commit the notes alone, for example `docs: add release notes for X.Y.Z`, and push them to `main` once the user approves that push.

## 3. Release

1. Wait until CI on `origin/main` has passed; `just release` refuses otherwise.
2. With the user's approval, run `just release X.Y.Z` (or `just release` for the next patch). It prints the notes file it found, the `build.zig.zon` diff, and the workflow URL. Tags are signed; if signing fails, nothing is tagged or pushed. If `main` moved since the fetch, nothing is pushed; run it again.
3. Watch the Release workflow through completion. Confirm the release page shows the notes, both `monstar-X.Y.Z-<arch>-linux.tar.gz` tarballs, the source archive, and `SHA256SUMS`, and that the AUR packages moved to `X.Y.Z`.

If the workflow fails after the tag is pushed, report the failure and keep the tag while a recovery decision is made. A rerun of the failed jobs replaces the release's assets instead of failing on the existing release.
