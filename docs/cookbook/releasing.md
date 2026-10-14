# Cutting a release

Releases are tag-driven. The version is written once, in `build.zig.zon`, and pushing a `vX.Y.Z` tag that matches it runs [../../.github/workflows/release.yml](../../.github/workflows/release.yml), which publishes the release. What a release contains is in the root [README](../../README.md#releases).

1. Pick the version. niimbench is 0.x: a change to the editor, the CLI or the HTTP routes is a minor release (`0.Y.0`), and a fix is a patch release (`0.y.Z`).
2. In [CHANGELOG.md](../../CHANGELOG.md), move the entries under `## [Unreleased]` into a new `## [X.Y.Z] - YYYY-MM-DD` section below it, leave `## [Unreleased]` empty, and add the new version's link at the bottom. The release notes are that section, word for word.
3. Set `.version = "X.Y.Z"` in `build.zig.zon`. It is the only place the version is written; `niimbench --version` and the release workflow both read it.
4. Run `make test`, then build and check that the binary reports the new version:

   ```sh
   zig build && zig-out/bin/niimbench --version
   ```

5. Open a pull request with those changes, and merge it when CI is green.
6. Tag the merge on `main` and push the tag. These commands read the version from `main`'s `build.zig.zon`, so nothing in them is typed by hand:

   ```sh
   git fetch origin
   version=$(git show origin/main:build.zig.zon | sed -n 's/^ *\.version = "\([^"]*\)",.*/\1/p')
   git tag -a "v$version" origin/main -m "niimbench $version"
   git push origin "v$version"
   ```

7. Watch the release workflow. It fails, publishing nothing, if the tag is not on `main`, if it disagrees with `build.zig.zon`, or if `CHANGELOG.md` has no section for it. Otherwise it creates the release, then on an x86_64 and an arm64 runner re-runs `make test` (on arm64 without the browser checks, which need stable Chrome and run on x86_64), builds a static `ReleaseSafe` binary, checks that it reports the tag, and uploads its tarball, checksum and build provenance.

   A failed tag is deleted, fixed on `main` through a pull request, and pushed again. Deleting it takes:

   ```sh
   git push origin ":refs/tags/v$version"
   git tag -d "v$version"
   ```

## Check

The release page lists `niimbench-x86_64-linux.tar.gz` and `niimbench-aarch64-linux.tar.gz`, each with its `.sha256`. The newest one verifies and reports its own version:

```sh
gh release download --repo ywy50/niimbench --pattern 'niimbench-x86_64-linux.tar.gz*'
sha256sum -c niimbench-x86_64-linux.tar.gz.sha256
gh attestation verify niimbench-x86_64-linux.tar.gz --repo ywy50/niimbench
tar xzf niimbench-x86_64-linux.tar.gz
niimbench-x86_64-linux/niimbench --version
```
