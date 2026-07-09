# Releasing Beadazzle

This guide describes the release path implemented in the repository scripts and `.github/workflows/release.yml`.

## Release Goals

Each public release should produce:

- a signed `Beadazzle.app`,
- a notarized and stapled `Beadazzle-<version>.dmg`,
- a matching `.sha256` checksum,
- and a GitHub Release containing both artifacts.

## Required GitHub Environment

The release workflow expects a protected GitHub Actions environment named `public-beta-release`.

Configure that environment before the first public release:

1. Go to `Settings` → `Environments` → `New environment` and create `public-beta-release`.
2. Add at least one required reviewer so the publish job cannot access signing credentials without a human approval.
3. Add the signing and notarization values below as **environment secrets**, not plain repository secrets.
4. If your GitHub plan supports deployment branch or tag restrictions, limit the environment to your release tags such as `v*` and trusted branches only.

The environment must contain these secrets:

- `APPLE_DEVELOPER_ID_APPLICATION` — full signing identity name, for example `Developer ID Application: Example Name (TEAMID)`.
- `APPLE_DEVELOPER_ID_P12_BASE64` — base64-encoded `Developer ID Application` certificate export.
- `APPLE_DEVELOPER_ID_P12_PASSWORD` — password for the `.p12` export.
- `APPLE_NOTARY_APPLE_ID` — Apple ID used for notarization.
- `APPLE_NOTARY_TEAM_ID` — Apple Developer team identifier.
- `APPLE_NOTARY_APP_PASSWORD` — app-specific password for the notarization Apple ID.

## Apple Certificate Setup Checklist

Once your Apple Developer Program membership is active, the shortest path is:

1. In Apple’s Certificates, Identifiers & Profiles area, create a `Developer ID Application` certificate.
2. Install that certificate into your Mac keychain.
3. Export it from Keychain Access as a password-protected `.p12` file.
4. Base64-encode the export for GitHub:

```bash
base64 -i ~/path/to/DeveloperID.p12 | pbcopy
```

5. Save the copied value as `APPLE_DEVELOPER_ID_P12_BASE64` in the `public-beta-release` environment.
6. Save the `.p12` export password as `APPLE_DEVELOPER_ID_P12_PASSWORD`.
7. Save the full signing identity string, such as `Developer ID Application: Your Name (TEAMID)`, as `APPLE_DEVELOPER_ID_APPLICATION`.
8. Create an app-specific password for the Apple ID you will use with notarization and save it as `APPLE_NOTARY_APP_PASSWORD`.
9. Save the Apple ID email as `APPLE_NOTARY_APPLE_ID` and your Apple team identifier as `APPLE_NOTARY_TEAM_ID`.

You can inspect the exact identity string locally with:

```bash
security find-identity -v -p codesigning
```

## Local Dry Run Commands

You can validate most of the pipeline locally before pushing a tag.

### Metadata helper

```bash
./script/test_release_common.sh
```

### Standard app checks

```bash
rtk swift build
rtk swift test
rtk ./script/build_and_run.sh --verify
```

### Build a signed app bundle

```bash
./script/build_app_bundle.sh \
  --release-tag v1.0.0 \
  --build-number 100 \
  --codesign-identity "Developer ID Application: Example Name (TEAMID)" \
  --configuration release
```

### Notarize the app bundle

```bash
APPLE_ID="name@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./script/notarize_release.sh --app-bundle dist/Beadazzle.app
```

### Build the DMG

```bash
./script/create_release_dmg.sh \
  --release-tag v1.0.0 \
  --build-number 100 \
  --codesign-identity "Developer ID Application: Example Name (TEAMID)" \
  --configuration release \
  --app-bundle dist/Beadazzle.app
```

### Notarize and staple the DMG

```bash
APPLE_ID="name@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./script/notarize_release.sh \
  --dmg-path dist/Beadazzle-0.1.0-beta.1.dmg \
  --checksum-path dist/Beadazzle-0.1.0-beta.1.dmg.sha256
```

## GitHub Actions Flow

`release.yml` supports two entrypoints:

- pushing a version tag that matches `v*`,
- or manually starting `workflow_dispatch` with `release_tag` and optional `target_ref` / `build_number` inputs.

The workflow does the following, in order:

1. Resolve the release tag, checkout ref, and bundle build number.
2. Run `swift test` and `./script/test_release_common.sh` before any signing secrets are exposed.
3. Pause at the protected `public-beta-release` environment until a reviewer approves the publish job.
4. Fail early if any signing or notarization secret is missing.
5. Import the `Developer ID Application` certificate into a temporary keychain.
6. Build the signed app bundle.
7. Notarize and staple the app bundle.
8. Build the signed DMG from the stapled app bundle.
9. Notarize and staple the DMG, then regenerate the checksum.
10. Create or update the GitHub Release and upload the DMG plus checksum.

## Tagging Convention

Use version tags such as:

- `v1.0.0`
- `v0.1.0-beta.1`
- `v0.1.0`

The scripts strip the leading `v` for artifact naming and derive:

- `CFBundleShortVersionString` from the semantic-version core,
- `CFBundleVersion` from the workflow build number or the explicit `--build-number` value.

## Operational Notes

- `script/build_and_run.sh` remains the local launch entrypoint; release packaging is layered under separate reusable helpers.
- `create_release_dmg.sh` always writes a checksum, but `notarize_release.sh` rewrites the checksum after stapling so the published checksum matches the final DMG.
- Local ad-hoc builds are fine for development, but Gatekeeper acceptance checks should be expected to pass only for real `Developer ID` signed and notarized release artifacts.
- The publish job uses a dedicated environment so signing credentials stay unavailable to the earlier validation job and every release has an approval audit trail.
