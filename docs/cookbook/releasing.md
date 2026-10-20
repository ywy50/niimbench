# Cutting a release

Releases are tag-driven. The version is written once, in `build.zig.zon`, and pushing a `vX.Y.Z` tag that matches it runs [../../.github/workflows/release.yml](../../.github/workflows/release.yml), which publishes the release. What a release contains is in the root [README](../../README.md#releases).

1. Pick the version. niimbench is 0.x: a change to the editor, the CLI or the HTTP routes is a minor release (`0.Y.0`), and a fix is a patch release (`0.y.Z`).
2. In [CHANGELOG.md](../../CHANGELOG.md), move the entries under `## [Unreleased]` into a new `## [X.Y.Z] - YYYY-MM-DD` section below it, leave `## [Unreleased]` empty, and at the bottom add the new version's compare link and start the `[Unreleased]` link at the new tag. The release notes are that section, word for word.
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

7. Watch the release workflow. It fails, publishing nothing, if the tag is not on `main`, if it disagrees with `build.zig.zon`, or if `CHANGELOG.md` has no section for it. Otherwise it creates the release, then on an x86_64 and an arm64 runner re-runs `make test` (on arm64 without the browser checks, which need stable Chrome and run on x86_64), runs `tools/linux-dist.sh` for the static `ReleaseSafe` binary, its tarball, `.deb` and `.rpm`, installs each package in a Debian and a Fedora container with `tools/linux-package-check.sh`, and uploads them with their checksums and build provenance. A Mac runner re-runs `zig build test`, builds the Mac app with `tools/macos-app.sh`, opens it with `tools/macos-app-check.sh`, and uploads `niimbench-macos.zip` the same way. Once the Linux files are up, an `aur` job writes the AUR package `niimbench-bin` from their checksums, builds and installs it on Arch, keeps its `PKGBUILD` and `.SRCINFO` on the run, and publishes them to the AUR when the repository has the key ([the AUR package](#the-aur-package)).

   A failed tag is deleted, fixed on `main` through a pull request, and pushed again. Deleting it takes:

   ```sh
   git push origin ":refs/tags/v$version"
   git tag -d "v$version"
   ```

## The AUR package

The release's `aur` job publishes `niimbench-bin` to the AUR with `tools/aur-push.sh`, which signs in with the SSH key in the repository secret `AUR_SSH_PRIVATE_KEY`. Until that secret exists the job says so and the release goes ahead without it. Setting it up is done once, by whoever will own the package on the AUR:

1. Make an account at [aur.archlinux.org](https://aur.archlinux.org/register), if there is none.
2. Make an SSH key for it alone, with no passphrase, since a workflow uses it:

   ```sh
   ssh-keygen -t ed25519 -N '' -C niimbench-aur -f ~/.ssh/niimbench-aur
   ```

3. Paste `~/.ssh/niimbench-aur.pub` into **My Account → SSH Public Key** on the AUR.
4. Give the private key to the repository:

   ```sh
   gh secret set AUR_SSH_PRIVATE_KEY --repo ywy50/niimbench < ~/.ssh/niimbench-aur
   ```

The next release then creates the package on its first push and updates it on every one after. A release made before that, or one whose push failed, is published by hand from the files its run kept, from the run's **niimbench-bin-aur** download, unzipped here as `PKGBUILD` and `.SRCINFO`:

```sh
git clone ssh://aur@aur.archlinux.org/niimbench-bin.git
cp PKGBUILD .SRCINFO niimbench-bin/
cd niimbench-bin
git add PKGBUILD .SRCINFO
git commit -m "niimbench-bin $(sed -n 's/^pkgver=//p' PKGBUILD)"
git push origin HEAD:master
```

## Check

The release page lists `niimbench-x86_64-linux` and `niimbench-aarch64-linux` as `.tar.gz`, `.deb` and `.rpm`, and `niimbench-macos.zip`, each with its `.sha256`. The newest Linux one verifies and reports its own version:

```sh
gh release download --repo ywy50/niimbench --pattern 'niimbench-x86_64-linux.tar.gz*'
sha256sum -c niimbench-x86_64-linux.tar.gz.sha256
gh attestation verify niimbench-x86_64-linux.tar.gz --repo ywy50/niimbench
tar xzf niimbench-x86_64-linux.tar.gz
niimbench-x86_64-linux/niimbench --version
```

On a Mac, the app's zip verifies the same way, and the app inside reports the version:

```sh
gh release download --repo ywy50/niimbench --pattern 'niimbench-macos.zip*'
shasum -a 256 -c niimbench-macos.zip.sha256
gh attestation verify niimbench-macos.zip --repo ywy50/niimbench
ditto -x -k niimbench-macos.zip .
niimbench.app/Contents/Helpers/niimbench.app/Contents/MacOS/niimbench --version
```
