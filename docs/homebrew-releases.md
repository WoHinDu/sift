# Homebrew releases

Sift follows Tern's dedicated-tap pattern: `dominik-bura/homebrew-sift`, with `Casks/sift.rb` generated from the production DMG's version and SHA-256. It installs the universal `Sift.app`, requires macOS Sonoma or newer, and declares `auto_updates true` for the in-app updater.

## One-time configuration

- Seed the public `dominik-bura/homebrew-sift` repository with `Casks/sift.rb` from a verified release.
- Set Sift's Actions variable `HOMEBREW_TAP_REPOSITORY` to `dominik-bura/homebrew-sift`.
- Create a fine-grained GitHub token with **Contents: read and write** on **only** that tap repository. Store it as Sift's Actions secret `HOMEBREW_TAP_TOKEN`. Do not copy Tern's token or reuse an interactive GitHub login token.

The release workflow tests the generator, builds/packages Sift, computes the final DMG checksum after signing/notarization, generates and syntax-checks the cask, publishes the release, then commits the cask to the tap. A failed tap push fails the workflow after publication and can be retried. Missing configuration emits a warning without blocking GitHub releases. The tap token is provided only to its publishing step, never embedded in the Git remote URL.

Unsigned releases retain their approval warning. The cask does not remove quarantine or bypass Gatekeeper. Normal uninstall quits/removes Sift; opt-in `brew uninstall --zap` additionally removes Sift's own support data and preferences, never projects or developer caches.

## Install

```bash
brew tap dominik-bura/sift
brew install --cask dominik-bura/sift/sift
```

The fully qualified install scopes trust to this cask instead of the entire tap. See [Homebrew tap trust](https://docs.brew.sh/Tap-Trust).

## Local validation

```bash
bash scripts/test-generate-cask.sh
```

Checks both signing modes, Ruby syntax, artifact naming, checksums, invalid inputs, and absence of automatic Gatekeeper bypasses. It does not install Sift, run cleanup, or prove remote publishing succeeded.
