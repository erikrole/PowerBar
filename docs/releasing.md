# Releasing PowerBar

**Retired October 23, 2026.** Version 0.1.1 (build 5) is the final release.
Repository archival and GitHub Actions shutdown await explicit approval.
The following procedure is retained for historical reference.

PowerBar is distributed directly as a signed and notarized Apple Silicon ZIP
attached to a GitHub Release. Homebrew is intentionally deferred until the app
has a stable release cadence.

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate and private key in the local
  keychain or in the release workflow's imported keychain.
- An App Store Connect API key authorized to submit notarization requests, or a
  local `notarytool` keychain profile.
- Xcode and XcodeGen.

If the checkout does not have a Developer ID Application identity, the release
script stops before archiving and explains what is missing.

## Local release

Use a keychain profile created for `notarytool`:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="PowerBar-notary" \
./scripts/release-macos.sh
```

Or provide an App Store Connect API key directly:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_KEY_ID="YOUR_KEY_ID" \
NOTARY_ISSUER_ID="YOUR_ISSUER_ID" \
NOTARY_PRIVATE_KEY_PATH="/path/to/AuthKey_KEYID.p8" \
./scripts/release-macos.sh
```

The script generates a Release archive, exports Developer ID-signed
`PowerBar.app`, submits a ZIP to Apple's notary service, staples the ticket,
and writes:

```text
.release/PowerBar-0.1.0-arm64.zip
.release/PowerBar-0.1.0-arm64.zip.sha256
```

## GitHub release

The release workflow runs when a `v*` tag is pushed. It expects these GitHub
Actions secrets:

- `APPLE_TEAM_ID`
- `DEVELOPER_ID_CERTIFICATE_P12` (base64-encoded certificate and private key)
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY` (base64-encoded `.p8` key)

After the secrets are configured:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow verifies that the tag matches `MARKETING_VERSION`, builds and
notarizes the arm64 app, calculates a SHA-256 checksum, and creates the GitHub
Release with both files attached.

Do not commit certificates, private keys, provisioning assets, or notarization
credentials.

## Verified updater release: 0.1.1 (build 5)

Published October 23, 2026 at [PowerBar 0.1.1](https://github.com/erikrole/PowerBar/releases/tag/v0.1.1). Source commit: `5b4877daeba861155c347da0542cabcd09fff0ec`. The app and its owned extensions/helpers require macOS 27.0 in Info.plist and Mach-O. The arm64 ZIP is Developer ID signed with Team `T26T3G8C7Q`, accepted by Apple notarization, stapled, and accepted by Gatekeeper after fresh extraction. ZIP/checksum/provenance digests match GitHub. Host tests: 44 reported, 0 skipped, zero failures. AppUpdater’s live download/verification path also passed for this public release.

## Rechecking an existing release

`./scripts/verify-published-release.sh v0.1.1` downloads and verifies the published ZIP, checksum, provenance, signing, notarization ticket, and macOS 27 minimum. It never changes release assets. To run the corrected workflow against an existing tag, dispatch the current main workflow with `gh workflow run release.yml --ref main -f tag=v0.1.1`. The workflow checks out the exact tag, preserves an existing published release, and validates its artifacts; new releases include the same provenance manifest.
