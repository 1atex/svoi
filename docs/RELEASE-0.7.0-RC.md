# Release candidate 0.7.0-rc.1 — review packet

Public GitHub release and production site deployment require the owner's separate approval. Do not create or push a release tag during preparation.

## Version and packages

Windows source version, Dart fallback, pubspec and installer parameter are 0.7.0-rc.1; display version is 0.7.0 Beta Release Candidate. Linux uses config/linux-release.json with the same RC version. Android and macOS retain their independent preview version series. iOS source and unsigned preview6 are preserved.

Build Windows with flutter_client/build-prototype.ps1. Dependencies are pinned and SHA-256-checked; optional core pins live in config/optional-cores.json. Runtime capabilities must agree with packaged executables. Native profile adapters deliberately reject unsupported options instead of dropping them.

## Authentic update signing

backend/update_public_key.go is the trust root compiled into the application and updater helper. The local private PEM stays in ignored .tools/release-signing/update-ed25519.pem with current-user/SYSTEM access only. Do not commit, upload as an artifact, or include this key in the installer. Back up the private key securely before deleting this checkout. Losing it requires an explicit trust-root migration and manual bootstrap update.

Sign a completed canonical setup with:

    go run ./cmd/sign-update-manifest -key .tools/release-signing/update-ed25519.pem -installer releases/v0.7.0-rc.1/SVOI-0.7.0-rc.1-windows-x64-setup.exe

The produced SVOI-0.7.0-rc.1-windows-x64-update.json must accompany the setup on the same release. Its Ed25519 signature binds exact payload bytes containing version, channel, platform, filename, byte size and SHA-256. The helper verifies again after the application exits. A checksum alone is never described as authenticity.

CI workflow_dispatch builds remain available without a secret. Tag publication fails closed without SVOI_UPDATE_SIGNING_KEY, signs the exact built installer, runs the actual signed-release verification test, and uploads the manifest. That secret has not been provisioned here. Configure it only as an owner-approved CI secret; never paste it into a PR, issue or command line. All beta/preview/rc tags are preliminary releases.

## Update and recovery behavior

Existing 0.6.0-beta.6 users can install the canonical RC setup manually after reviewing the artifact. Profiles/settings are outside the application directory. The RC can authenticate future unsigned executable packages via SVOI's manifest signature, without a paid Authenticode certificate. Windows logon notifications require enabling SVOI startup and automatic update checks; no startup task is silently created by this preparation.

Signed update installation uses full silent Inno Setup, not a delta payload. User-data backup and structured last-install diagnostics are kept under the updates directory. A bad signature is rejected before stopping VPN. There is no claim of atomic binary rollback or measured 20–30-second installation; use the previous verified setup and saved profile backup if manual recovery is needed.

## Site publication

The landing checkout contains one releases.json snapshot, source/build scripts, tests and a disabled-by-default deployment gate. Only published GitHub assets appear as public downloads. Site count means retained release binary downloads, including repeats and updates, not installations or users. Review svoi-landing/docs/RELEASE-SOURCE.md before enabling deployment. Production has not been changed.
