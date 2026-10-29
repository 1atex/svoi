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

## Publication sequence after separate owner approval

1. Review the actual Windows setup/ZIP/signed update JSON, Android signed APKs, Linux packages, macOS ARM64 ad-hoc DMG and preserved unsigned iOS IPA. Keep their independent platform versions and signing limitations explicit. Select exactly which packages are approved; do not label the RC as stable.
2. Securely back up the existing local update-signing private key and provision its PEM as the app repository's `SVOI_UPDATE_SIGNING_KEY` Actions secret. The embedded public key must remain the matching trust root. The secret is currently absent; tag publication deliberately fails without it.
3. Publish the approved app release assets and complete their notes/signature manifests. Use prerelease flags for RC/preview versions and verify the actual published asset hashes and architecture labels. Do not invent future URLs in the site snapshot.
4. Connect the reviewed landing source to an approved repository. It currently has no remote. The proposed destination is a separate private `svoi-site` repository under the owner account; it has not been created. Push its reviewed source to the default branch only after that choice is approved.
5. Configure the site's `svoi-production` environment, host/user variables and host-key-pinned SSH secrets described in `RELEASE-SOURCE.md`. Keep `SVOI_SITE_DEPLOY_ENABLED` disabled until these prerequisites and the first deployment are approved. It is currently disabled, and no deployment credentials were provisioned here.
6. Refresh the snapshot from the newly published app releases, build and test the site, then enable the gate and run the first approved production deployment. Verify the live snapshot and all approved download links. Subsequent six-hour runs use that same generator; optional immediate release dispatch requires separately configured cross-repository credentials. Required environment reviewers still make each deployment wait for approval.

Preparation is complete only for the local artifacts and reviewed source. The steps above are not already-running release or site automation and have not been executed during this task.

## Verification recorded on 30 October 2026 (Moscow time)

| Platform | Artifact source | Evidence |
| --- | --- | --- |
| Windows 0.7.0-rc.1 | `f9d00e2` | Native Go suite/vet; Flutter analyzer and 112 tests passed, 2 platform skips; final setup Ed25519 verification and focused recovery/mutex tests passed; final packaged backend exposed and selected all three cores; ZIP CRC and private-key exclusion passed. Actual Windows screenshots use the built EXE with demo data. |
| Android preview.13 | `9a2a714` | [CI 40964198782](https://github.com/1atex/svoi/actions/runs/40964198782) succeeded: 105 Flutter tests, 1 skip, signed release APKs, emulator VPN with 20 reconnects, update checks and in-place upgrade from published Preview 8. |
| Linux 0.7.0-rc.1 | `583fdce` | [CI 40967340073](https://github.com/1atex/svoi/actions/runs/40967340073) succeeded: native Go tests with all packaged cores, vet, 38 Flutter tests, local/TUN real HTTP traffic and five reconnects each, ten normal GUI close cycles without a debugger, Debian installation and installed-backend traffic. The Linux-only shutdown fix preserves the render scene and disconnects native callbacks before destroying the window. |
| macOS preview.5 | `6b78023` | [CI 40963566410](https://github.com/1atex/svoi/actions/runs/40963566410) succeeded: ARM64 DMG build/signature validation, interface/backend checks and proxy/reconnect smoke. Screenshot uses demo data; DMG is ad-hoc signed, not notarized. |
| iOS preview.6 | `b6c96af` preserved | Existing unsigned IPA and its prior simulator verification are unchanged. This task did not run a new physical-device test or add provisioning. |

The Windows setup was **not installed over the owner's running installation**. Authentication, helper behavior, profile backups, notification delivery, mutex waiting and packaged core selection were checked, but this is not an end-to-end timed upgrade or proof of automatic binary rollback. The current installed app and network settings were left untouched.

Final public-site source snapshot: `2026-10-29T22:35:28Z`, 26 published releases, 62 binary assets, 240 download events (Windows 157, Android 65, Linux 18). Seven contract tests and a real 362px browser review passed. The snapshot includes published beta.6/Android preview.12/Linux preview.3; the prepared builds above remain unpublished. Site archive SHA-256: `f572895cbcc80844ab07990286a3b4da125c9c66f8666f5259bd45f7dc52ea81`.
