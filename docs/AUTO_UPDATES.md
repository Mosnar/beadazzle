# Auto-updates (Sparkle) & changelog

Beadazzle ships automatic updates via [Sparkle 2](https://sparkle-project.org).
On first launch Sparkle asks whether to enable automatic update checks (its
standard opt-in). Once enabled, it checks an appcast feed in the background and
presents a changelog with **Install** / **Skip**. A **Check for Updates…** item
lives in the app menu, and the **Updates** settings pane exposes automatic-check
and beta-channel toggles.

- **Feed:** `https://mosnar.github.io/beadazzle/appcast.xml` (GitHub Pages)
- **Downloads:** the notarized DMGs already attached to each GitHub Release
- **Channels:** pre-release tags (`vX.Y.Z-beta.N`) are published to the `beta`
  channel; final tags (`vX.Y.Z`) go to the default (stable) channel. Users only
  see beta items if they enable "Receive beta updates".

The release workflow (`.github/workflows/release.yml`) builds the app, notarizes
it, publishes the GitHub Release, regenerates the appcast, and deploys it to
Pages — all from a tag push. The pieces below are the **one-time setup** that
must be done by a human before the first Sparkle-enabled release.

## One-time setup

### 1. Generate the EdDSA signing key

Sparkle signs each update with an EdDSA (ed25519) key. The **public** key is
baked into the app; the **private** key signs the appcast in CI.

```bash
# Download the Sparkle tools (match SPARKLE_TOOLS_VERSION in the workflow / Package.swift)
curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz | tar -xJ bin/
./bin/generate_keys                     # creates the private key in your login Keychain, prints the PUBLIC key
./bin/generate_keys -x private-key.txt  # exports the base64 PRIVATE key to a file
```

Keep `private-key.txt` out of git (delete it after step 3). The public key is
not secret.

### 2. Publish the public key

Set it as a **repository variable** so the build can bake it into `Info.plist`:

- GitHub → Settings → Secrets and variables → Actions → **Variables** tab
- New variable: `SPARKLE_ED_PUBLIC_KEY` = the public key printed in step 1

(Optional) for local release builds, paste the same value into
`BEADAZZLE_SPARKLE_PUBLIC_KEY` in `script/release_common.sh`. Not needed for CI.

### 3. Publish the private key

Set it as a **secret** in the same environment as the Apple signing secrets:

- GitHub → Settings → Environments → **public-beta-release** → Add secret
- `SPARKLE_ED_PRIVATE_KEY` = the full contents of `private-key.txt`

Then `rm private-key.txt`.

### 4. Enable GitHub Pages

- GitHub → Settings → **Pages** → Source = **GitHub Actions**

The `deploy_appcast` job publishes `appcast.xml` here. After the first release,
confirm the feed loads at `https://mosnar.github.io/beadazzle/appcast.xml`.

## Cutting a release

1. Move the finished items in `CHANGELOG.md` from `## [Unreleased]` into a new
   `## [X.Y.Z-beta.N]` heading (with the date), and add fresh link references at
   the bottom. Leave a new empty `## [Unreleased]` section.
2. Commit, then tag and push: `git tag vX.Y.Z-beta.N && git push --tags`.

The workflow then:
- runs tests, builds + notarizes the signed DMG,
- reads the matching `CHANGELOG.md` section for both the GitHub Release notes
  and the in-app update dialog (**the release fails if that section is
  missing** — this keeps notes honest),
- regenerates and re-signs the appcast (preserving prior entries) and deploys it
  to Pages.

## Notes & gotchas

- **The current `v0.1.0-beta.1` build predates Sparkle**, so already-installed
  copies can't self-update to the first Sparkle release — that one is a manual
  download. Every release after it updates automatically.
- The app is **not sandboxed**, so the build strips Sparkle's `XPCServices` and
  signs the framework inside-out (see `beadazzle_release_sign_sparkle`). Don't
  reintroduce `codesign --deep` on the app bundle.
- Release notes are embedded into the appcast from the rendered changelog HTML.
  After the first release, open the appcast and confirm the `<description>`
  renders the way you expect in the update dialog.
