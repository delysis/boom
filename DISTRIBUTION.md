# Bloom distribution preparation

As of the user's October 7, 2026 scope update, current delivery requires a runnable Apple Development signed local bundle and verified installation/relaunch. Developer ID signing and notarization are future release work, not blockers for current completion. The release workflow below remains available for that later work; do not describe a development build as notarized or Gatekeeper-qualified distribution.

The default build is an Apple Development build for local work. Distribution is a separate, explicit build profile. It requires a Developer ID Application identity and requests Apple's secure signing timestamp. Both profiles verify the actual signature, hardened-runtime bit, microphone entitlement, signed identity and privacy descriptions, source/lock inventories and model catalog through the workspace's safe Rust `bloom-delivery` tool. The tool records each native command, output and result before proceeding. It does not run Bloom, access its vault, submit to Apple or publish weights.

Apple describes the certificate, timestamp and hardened-runtime requirements in [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), and submission/stapling in [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Bloom deliberately supports its current single-executable bundle. Unexpected nested executables or resource symlinks refuse preparation rather than receiving blanket signing permissions.

Set `BLOOM_SIGN_IDENTITY` locally to the full Developer ID Application identity or its fingerprint. Keep the signing identity stable across builds. Build each edition into a different fresh directory:

```sh
scripts/build-macos.sh "$PWD/out/author-distribution" author distribution
scripts/build-macos.sh "$PWD/out/chat-distribution" chat distribution
```

An unavailable identity, wrong certificate type, failed timestamp service or failed signature check leaves evidence and fails the build. There is no fallback to development signing. Development retains its existing designated requirement and no timestamp-server request. Distribution builds require network access for Apple's signing timestamp; app startup and inference remain local operations.

The consolidated gate builds the delivery tool at `target/release/bloom-delivery` (or `target/chat/release/bloom-delivery` for chat). Independently inspect any exact bundle into fresh evidence:

```sh
target/release/bloom-delivery inspect \
  "$PWD/out/author-distribution/Bloom.app" "$PWD/out/author-inspection"
```

Create a submission archive from the approved, exact build:

```sh
target/release/bloom-delivery archive \
  "$PWD/out/author-distribution/Bloom.app" "$PWD/out/author-submission" submission
```

The archive command requires the actual Developer ID Application certificate and secure timestamp. It copies the app into its evidence directory, verifies the copy and compares its identity with the original, then archives only that copy with `ditto`. External model caches, workspaces and source archives are outside the archive input. The ZIP hash, native command outputs and source/build/catalog identities are retained. This is local preparation, not release approval or notarization acceptance.

Configure notary credentials separately using Apple's `notarytool store-credentials`; no credentials belong in source, chat, command receipts or the app vault. Use a named Keychain profile. Submission is an explicit developer action after reviewing the archive and licenses. Submit the exact prepared ZIP once, retaining JSON output and the Apple submission ID. For example, after replacing the profile name with the locally configured one:

```sh
xcrun notarytool submit \
  "$PWD/out/author-submission/delivery/Bloom-author.zip" \
  --keychain-profile BloomNotary --output-format json \
  > "$PWD/out/author-submission/notary-submission.json"
```

Use `notarytool info` and `notarytool log` with that ID and the same profile to inspect status and retain results. A timeout or uncertain response is not permission to submit again. If interrupted before receiving an ID, resolve the existing submission through Apple's history before any new submission. Accepted status must refer to this exact archive; preserve rejected results and logs.

After acceptance, staple the **copied app inside the submission evidence**, not the original build or an older sealed deliverable:

```sh
xcrun stapler staple "$PWD/out/author-submission/delivery/bundle/Bloom.app"
target/release/bloom-delivery archive \
  "$PWD/out/author-submission/delivery/bundle/Bloom.app" \
  "$PWD/out/author-notarized" notarized
```

The notarized stage checks the copied app with `stapler validate` and Gatekeeper before creating a new ZIP. Retain both ZIPs: the submission ZIP and the later stapled ZIP have different identities. Neither stage counts as installation or relaunch acceptance. Run both editions' exact final artifacts on a clean target Mac, including quarantine/Gatekeeper, offline launch, cache-based model setup, actual Keychain dialogs, microphone approval and denial, on-device speech, quit/relaunch and the two native demonstrations. Performance uses the approved 24 GiB application budget on the development Mac, including paired full-context generation and loading peaks; an actual 32 GiB MacBook is no longer required. Record the final bundle, source/lock/catalog hashes, model manifests, Apple submission ID, assessment outputs, measured hardware and failures.

Only an Apple Development identity is currently available on the 128 GiB development Mac. Future public-release signing, secure timestamps, Apple acceptance, stapling and Gatekeeper installation remain unqualified and are outside the current delivery gate. Verify local installation and relaunch with the available identity. The separately approved 24 GiB application performance gate remains applicable. Review licenses before public distribution; collecting notices alone does not approve it. Source stays in the private repository and model packs remain local.
