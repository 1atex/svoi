# SVOI 0.7.0 Beta Release Candidate — publication record

## Current published builds — 30 October 2026

- [Windows RC4](https://github.com/1atex/svoi/releases/tag/v0.7.0-rc.4): tg-ws-proxy is bundled in the zapret tools. The Windows release job passed; the public Ed25519 update manifest matches the installer hash, size and version. Flutter: 145 passing tests, 4 platform skips; native Go suite and packaged proxy lifecycle checks passed. Telegram account traffic was not tested.
- [Android preview.14](https://github.com/1atex/svoi/releases/tag/android-v0.1.0-preview.14): signed ARM64/x64 APKs and update manifest published, signing identity retained, emulator checks passed.
- [macOS preview.6](https://github.com/1atex/svoi/releases/tag/macos-v0.6.0-preview.6): Apple Silicon DMG, package install and launch checks passed. Ad-hoc signed, not notarized; no TUN.
- [iOS preview.7](https://github.com/1atex/svoi/releases/tag/ios-v0.1.0-preview.7): unsigned IPA and matching sources; compact and Pro simulator checks passed. Installation still requires signing both the app and Packet Tunnel extension with compatible provisioning.
- [Linux RC6](https://github.com/1atex/svoi/releases/tag/linux-v0.7.0-rc.6): DEB and portable archive from commit `2c6715d9e324dc8b4e6c2018cc9c1348b0d114b1`. The [build](https://github.com/1atex/svoi/actions/runs/41070054873) passed code checks, 38 UI tests, local/TUN reconnects, 20 GUI close cycles and Debian installation. Only GitHub publication failed with HTTP 500; the [artifact publication](https://github.com/1atex/svoi/actions/runs/41071817283) then verified the source, completed checks, package checksums and uploaded asset digests before publishing. Renderer widgets are retained until engine shutdown completes; an additional 20 local close cycles under GDB passed.

The site snapshot and README now link these builds. Windows and Android public update metadata were verified after publication.

## Archived RC1 publication record

The owner approved publication on 30 October 2026 after the optional-core ping fix. Four platform releases were published from drafts only after all listed assets and hashes were verified. Linux RC remains unpublished because its native GUI exit can still crash; the public Linux preview.3 is retained.

## Published packages

| Platform | Source | Release and validation |
| --- | --- | --- |
| Windows 0.7.0-rc.1 | `f3042e623a725beac618c80078c2b41ec47de546` | [Release](https://github.com/1atex/svoi/releases/tag/v0.7.0-rc.1): canonical setup, ZIP, checksums and Ed25519 update manifest. Flutter analyzer and 114 tests passed (2 platform skips); full native Go suite and vet passed; final installer signature, packaged core selection and ZIP CRC passed. |
| Android preview.13 | `9a2a714a16ab11950cf049b933ff84de9d2f1c1c` | [Release](https://github.com/1atex/svoi/releases/tag/android-v0.1.0-preview.13), [CI](https://github.com/1atex/svoi/actions/runs/40964198782): signed ARM64/x64 APKs, 105 Flutter tests, VPN with 20 reconnects on emulator, update checks and in-place upgrade from published Preview 8. |
| macOS preview.5 | `6b78023e242bbc4eb4ae094c8b0dafaae9b23a1f` | [Release](https://github.com/1atex/svoi/releases/tag/macos-v0.6.0-preview.5), [CI](https://github.com/1atex/svoi/actions/runs/40963566410): Apple Silicon ARM64 DMG, ad-hoc signature, no Apple notarization; backend/UI/proxy checks passed. |
| iOS preview.6 | `b6c96af217798d71b66cc934584f674c6e3f8a49` | [Release](https://github.com/1atex/svoi/releases/tag/ios-v0.1.0-preview.6): preserved unsigned IPA and matching source archive. The app and Packet Tunnel extension require appropriate signing, provisioning and Network Extension entitlements. An Apple ID alone is insufficient. Prior simulator validation is preserved; no new physical-device test is claimed. |

Windows setup: 65,248,345 bytes, SHA-256 `ad4edfafcc8714a2558c64d42f36ade11be0f6851e222d24253812beaffafad3`.
Windows ZIP SHA-256: `5196454a21255704c9a2001b4aea8cff31887aacd424facf5c4e9a8e840f05db`.
Signed manifest SHA-256: `f64b4220076fffa611a66c6791dafa6283150208e6b26db594eab4751fb1642a`.

## Ping correction and profile semantics

The immediate failure was not a measured timeout: complete Xray profiles with provider routing/balancers were rejected with HTTP 422, while the UI incorrectly called every non-startup error "No response". The UI now distinguishes unsupported profiles, core preparation errors, actual deadlines and other network errors. Switching cores clears persisted probe history as well as the visible result.

The native adapter accepts the lossless no-op cases `mux.enabled=false` with known fields and the default Reality `spiderX="/"`. Custom unsupported settings still fail explicitly. TLS fingerprints and certificate verification are not weakened. Both actual native executables passed a local Reality/QQ traffic fixture and a GET through an isolated copy of one real saved provider node: Xray 191 ms, sing-box 178 ms, Mihomo 178 ms. The running user VPN and original profile data were untouched. These are probe observations, not broad speed benchmarks or a claim that every Reality server version interoperates with every core.

Full Xray profiles are never silently flattened. The explicit "Create separate nodes" operation requires acknowledgment, preserves the original, creates a separate manual source, and warns that copies omit profile DNS, routing, balancing and fallback behavior. Copies do not refresh with the original subscription. Owner/authentication, persistence and source-preservation tests passed.

## Windows updates and signing

A real previous beta.6 backend was launched with isolated data and auto-download disabled; its live GitHub check reported `0.7.0-rc.1` available. The canonical SVOI filename works for that updater; no legacy Flutter-named asset is needed for beta.6. A previously tested unpublished RC with the same `0.7.0-rc.1` version needs the newly published setup manually because its version number is unchanged.

`backend/update_public_key.go` is the embedded Ed25519 trust root. The matching private PEM remains in ignored `.tools/release-signing/update-ed25519.pem` with restricted local access. Back it up securely; never include it in source or artifacts. The approved `SVOI_UPDATE_SIGNING_KEY` Actions secret was installed on 29 October 2026 at 22:55:41 UTC after matching its public key. CI requires a valid signing key before new tag publication and verifies the signed installer. The tag-triggered [publication guard](https://github.com/1atex/svoi/actions/runs/40972130869) passed and skipped rebuilding/replacing the manually verified release.

Signed updates use full silent Inno Setup, not a delta payload. Verification occurs before disconnecting VPN, then again in the helper. Recovery data and installation diagnostics are retained. No 20–30-second duration or automatic atomic binary rollback is promised. The new setup was not installed over the owner's running app during verification. Windows startup notifications require enabling SVOI startup and update checks; no startup task was silently created.

## Production site

The owner also approved the compact counter and removal of the visible counting-methodology section. The updated site is live at https://svoi.space/ and consumes one generated snapshot for versions, changelog, links and counts. Root verified public download links with HTTP 200 and matching byte sizes after the four releases.

Automation is now a real server-side systemd timer, `svoi-site-refresh.timer`, at 03:17, 09:17, 15:17 and 21:17 Moscow time with up to three minutes jitter. It runs the public GitHub generator, nine tests and the existing atomic installer. API failure, an empty invalid source or validation failure preserves the last working site. Source is private under `/var/lib/svoi-site/source`; no new private GitHub repository or server SSH key in GitHub Actions was required. The alternative GitHub deployment gate remains unused.

The first post-publication site snapshot was generated at `2026-10-29T23:18:16Z`; landing source commit `135df05`. Counts are retained binary-file download events, including repeats/updates, not unique people or installations; this method remains in developer documentation rather than a separate public page section.

## Linux RC held back

The earlier [583fdce validation](https://github.com/1atex/svoi/actions/runs/40967340073) passed ten normal GTK close cycles, but that did not eliminate the intermittent failure. The current [f3042e6 run](https://github.com/1atex/svoi/actions/runs/40970919257) passed native core/backend tests, 38 Flutter tests and local/TUN traffic, then exited with SIGSEGV during GUI close. Its RC packages are not approved for publication and must not be presented as the current verified release.

A separate diagnostic-only commit `1605dcf` enables post-mortem core capture without debugger attachment or a timing delay. [Diagnostic run 40971945789](https://github.com/1atex/svoi/actions/runs/40971945789) is tracked separately. No Linux RC tag/release was created; previous local artifacts are retained only as historical test outputs. Further Linux debugging is separate from the four published releases.
