# Releasing Hangtime

For maintainers. Releases are universal (Apple silicon and Intel), signed with Developer ID and notarized.

```sh
./scripts/release.sh 1.2.0           # bump the version on main; GitHub Actions builds and publishes
./scripts/release.sh 1.2.0 --local   # same, but build and publish from this Mac
./scripts/build-release.sh 1.2.0     # dry run: signed, notarized zip + DMG in dist/1.2.0, nothing published
```

A release ships only when `MARKETING_VERSION` in `project.yml` changes on `main` to a version without a tag
([`release.yml`](../.github/workflows/release.yml)). The workflow then:

1. builds, signs and notarizes the zip and DMG,
2. tags `v1.2.0` and creates the GitHub release with generated notes,
3. updates the cask in [Sevi-py/homebrew-tap](https://github.com/Sevi-py/homebrew-tap).

Every other push only runs CI ([`ci.yml`](../.github/workflows/ci.yml)), which builds a universal binary using
Xcode's compilation cache.

## Repository secrets

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect team API key (Admin role), for notarization |
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | The Developer ID Application certificate (base64 `.p12`) and its password |
| `TAP_DEPLOY_KEY` | Private SSH key of a deploy key with write access on `Sevi-py/homebrew-tap` |

## Releasing from a Mac (`--local` and dry runs)

- Xcode signed in with an account on team `8XX544GLPH` (Flarely e.U.), which provides the cloud-managed
  Developer ID certificate.
- Notarization credentials in the Keychain:
  `xcrun notarytool store-credentials hangtime-notary --apple-id <id> --team-id 8XX544GLPH --password <app-specific>`
- `gh` signed in with push access to this repo, and git credentials that can push to `Sevi-py/homebrew-tap`.
