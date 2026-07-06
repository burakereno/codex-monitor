# Release Signing

Codex Monitor release builds are Developer ID signed and notarized in GitHub Actions. Configure these repository secrets before pushing a release commit to `main`:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## Certificate

Create or download a **Developer ID Application** certificate from Apple Developer, install it in Keychain Access, then export the certificate and private key as a `.p12` file.

Convert the `.p12` for GitHub:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste that value into `MACOS_CERTIFICATE_P12_BASE64`. Use the `.p12` export password for `MACOS_CERTIFICATE_PASSWORD`. `KEYCHAIN_PASSWORD` can be any strong random password used only by the workflow's temporary keychain.

## Notarization

Create an app-specific password for the Apple ID used by the Developer account, then set:

- `APPLE_ID`: Apple ID email
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password

The release workflow signs the app with hardened runtime, notarizes and staples the app, creates the DMG, signs the DMG, notarizes and staples the DMG, then publishes the release asset.
