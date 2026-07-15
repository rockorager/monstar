---
name: releasing-monstar
description: Prepares and tags Monstar releases using semantic versions, checked-in release notes, and guarded verification. Use when drafting release notes, cutting a release, creating a version tag, or checking release readiness.
---

# Releasing Monstar

Prepare portable Monstar releases whose source of truth is a Git commit, a
signed semantic-version tag, and checked-in Markdown release notes. Publishing
is the responsibility of the repository's configured CI.

## Release contract

- Use versions in `X.Y.Z` form and tags in `vX.Y.Z` form.
- Store notes at `docs/releases/X.Y.Z.md`.
- Commit the version and release notes before creating the tag.
- Create the tag from that clean release commit.
- Treat hosted release pages and downloadable artifacts as projections of the
  tag and checked-in notes, not as primary release data.
- Keep notes provider-neutral. Do not add forge-generated compare links,
  provider-specific boilerplate, or publishing instructions to them.
- Let configured CI publish the release. Do not manually publish unless the
  user explicitly requests an exception.

## Safety rules

- Never discard, stage, or commit unrelated work. If unrelated changes prevent
  a clean release commit, report them and stop.
- Never create a tag, push a commit, or push a tag without explicit approval
  for that action. Approval to tag does not imply approval to push.
- Create signed tags. If signing is unavailable, stop rather than silently
  creating an unsigned tag.
- Never move, replace, or delete a published tag without explicit approval and
  a clear explanation of the consequences.
- Do not change CI configuration as part of a release unless separately asked.

## 1. Establish the release

1. Confirm the requested version and release date.
2. Confirm the current branch and inspect `git status --short --branch`.
3. Fetch remote state without changing the worktree, then confirm the release
   commit will be based on the intended branch and is not behind its upstream.
4. Confirm `vX.Y.Z` does not already exist locally or remotely.
5. Find the previous reachable Monstar release tag with:

   ```sh
   git describe --tags --abbrev=0 --match 'v[0-9]*'
   ```

   If there is no previous tag, treat this as the first release. Do not pull
   unrelated or inherited project history into the notes.
6. Inspect the commit range and relevant diffs. Describe user-visible outcomes,
   not every commit subject or internal refactor.
7. Inspect the configured CI and verify that a `vX.Y.Z` tag will run the release
   pipeline and that the pipeline consumes `docs/releases/X.Y.Z.md`. If that
   contract is absent, report it before tagging.

## 2. Write portable release notes

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

Keep only sections that have content. Add `## Upgrade notes` when users must
take action. For the first release, summarize the supported experience and
major capabilities instead of fabricating a change comparison.

Release notes must:

- Stand alone when read from a source archive or another forge.
- Be factual and verified against the code or documentation.
- Lead with impact and omit implementation trivia.
- Call out breaking changes, migrations, known limitations, and changed
  requirements when applicable.
- Avoid empty sections, raw commit dumps, and unverified claims.

The checked-in file is the exact release description that CI should publish.

## 3. Set the intended version

Update both version declarations to `X.Y.Z`:

- `release_version` in `build.zig`
- `.version` in `build.zig.zon`

Keep them identical. Monstar derives development identifiers from Git:

- An exact clean `vX.Y.Z` tag reports `X.Y.Z`.
- Other Git commits report `X.Y.Z-dev.<distance>+g<sha>`.
- Dirty builds append `.dirty`.
- Source archives without Git metadata report `X.Y.Z`.

If development has continued after the previous release, `release_version`
must be newer than that release tag.

## 4. Verify the release commit

Run checks in this order:

```sh
zig build test --summary all
zig build --summary all
zig build -Doptimize=ReleaseFast --summary all
zig build fmt
```

Formatting stays last. Report the exact pass, failure, and skip counts; do not
hide known warnings. Then inspect the binary version:

```sh
./zig-out/bin/monstar --version
```

Before tagging, a clean release commit is still a development build and should
report the intended `X.Y.Z` plus a development identifier.

Review `git diff --check`, the complete release diff, and the final status.
Commit only the intended version declarations and release note. Follow the
repository's commit-message guidance and use a release-focused subject such as
`release: prepare X.Y.Z` with a body explaining the release boundary.

## 5. Tag and verify

After the release commit is clean and the user explicitly approves tagging,
create a signed annotated tag:

```sh
git tag -s vX.Y.Z -m "Monstar X.Y.Z"
```

Build from the tagged commit and verify the stable identifier:

```sh
zig build -Doptimize=ReleaseFast --summary all
./zig-out/bin/monstar --version
```

The output must be exactly `monstar X.Y.Z`. Inspect the tag signature and
target before proposing a push. If verification fails, stop. Do not move or
delete the tag without approval.

## 6. Push and observe CI

After explicit push approval:

1. Push the release commit.
2. Push `vX.Y.Z` without pushing unrelated tags.
3. Observe the configured CI through completion.
4. Confirm that published notes match `docs/releases/X.Y.Z.md` and that any
   artifacts identify themselves as `X.Y.Z`.

If CI fails after publication, report the failure and preserve the tag while a
recovery decision is made. Do not rewrite release history automatically.

## 7. Resume development

After the release succeeds, ask for the next intended version. Before landing
another development commit, update both `release_version` and `.version` to a
version newer than `X.Y.Z`; otherwise Monstar intentionally rejects a
development build whose intended version is not newer than its nearest tag.

Make the post-release version bump a separate commit. Do not modify the
immutable notes for `X.Y.Z` except to correct a material factual error with an
explicitly reviewed follow-up.
