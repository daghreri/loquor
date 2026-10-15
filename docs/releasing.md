# Releasing Loquor

A release is a GitHub Release with four files: the standard and offline builds,
each as a DMG and a zip. Everything runs from the terminal with the Xcode
**Command Line Tools**; Xcode itself isn't needed.

## Why sign and notarize

Without it, macOS 15 and later refuse to open a downloaded Loquor until each
user goes to **System Settings › Privacy & Security › Open Anyway**, for every
new version, and macOS asks for their login password once after each update
before Loquor can read its API key from the Keychain.

Signed with a **Developer ID** and **notarized** by Apple, Loquor opens like any
other app, and updates keep their permissions and Keychain access without
prompts (macOS ties them to your Team ID instead of to each build).

## One-time setup

### 1. Join the Apple Developer Program

<https://developer.apple.com/programs/enroll/>, $99 a year.

- **As an individual:** your own name appears as the developer. Quickest.
- **As an organization:** the company name appears. Needs a D-U-N-S number and
  takes a few days longer.

### 2. Create a "Developer ID Application" certificate

Only the Account Holder can create it, on the website (Apple refuses this through
the App Store Connect API). The private key is made on your Mac.

```bash
# A private key and a certificate signing request (CSR). Keep the key safe.
# /usr/bin/openssl is macOS's own (LibreSSL); its .p12 files import cleanly.
/usr/bin/openssl req -new -newkey rsa:2048 -nodes \
  -keyout ~/loquor-devid.key -out ~/loquor-devid.csr \
  -subj "/emailAddress=you@example.com/CN=Your Name/C=US"
```

1. Go to <https://developer.apple.com/account/resources/certificates/add>.
2. Choose **Developer ID Application** (G2 Sub-CA), upload `~/loquor-devid.csr`,
   download the `.cer`.
3. Import the certificate and its key into your login keychain:

```bash
/usr/bin/openssl x509 -inform DER -in ~/Downloads/developerID_application.cer -out ~/loquor-devid.pem
/usr/bin/openssl pkcs12 -export -inkey ~/loquor-devid.key -in ~/loquor-devid.pem \
  -name "Developer ID" -out ~/loquor-devid.p12        # asks for an export password
security import ~/loquor-devid.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security find-identity -v -p codesigning             # shows "Developer ID Application: …"
rm ~/loquor-devid.pem ~/loquor-devid.csr              # keep the .key and .p12 backed up safely
```

If `codesign` later can't find the chain, install Apple's intermediate
certificate "Developer ID - G2" from <https://www.apple.com/certificateauthority/>.

**Back up the `.p12` somewhere safe** (a password manager). Every release must be
signed with the same Team ID, or users lose their permissions on update.

### 3. Save notarization credentials

Create an app-specific password at <https://account.apple.com> › Sign-In and
Security › App-Specific Passwords, then:

```bash
xcrun notarytool store-credentials loquor \
  --apple-id you@example.com --team-id YOURTEAMID --password <app-specific-password>
```

Your Team ID is on <https://developer.apple.com/account> › Membership details.
The credentials are stored in your Keychain under the profile name `loquor`.

## Each release

```bash
# 1. Bump the version in Resources/Info.plist:
#    CFBundleShortVersionString (e.g. 0.2.0) and CFBundleVersion (always increase)
# 2. Tag it
git tag v0.2.0 && git push origin v0.2.0

# 3. Build, sign, notarize and staple both flavours (a few minutes each)
export LOQUOR_NOTARY_PROFILE=loquor
scripts/package.sh                   # build/Loquor-0.2.0.zip and .dmg
scripts/package.sh --bundle-model    # build/Loquor-0.2.0-offline.zip and .dmg

# 4. Check what a user's Mac will say
spctl -a -vv -t install build/Loquor-0.2.0.dmg   # "accepted, source=Notarized Developer ID"

# 5. Publish
gh release create v0.2.0 build/Loquor-0.2.0*.dmg build/Loquor-0.2.0*.zip \
  --title "Loquor 0.2.0" --notes-file CHANGELOG.md
```

`scripts/build-app.sh` picks the Developer ID identity automatically when it's
in your keychain (or set `LOQUOR_SIGN_IDENTITY`). `scripts/package.sh` notarizes
only when `LOQUOR_NOTARY_PROFILE` is set and the app is signed with a Developer ID.

The offline build needs the speech model on the building Mac: run Loquor once so
it downloads to `~/Library/Application Support/Loquor/Models`.

## Releasing without a Developer ID

Possible, but say so clearly in the release notes:

> This build isn't notarized. After opening it, go to System Settings › Privacy
> & Security and click **Open Anyway**. You'll be asked again for each new
> version, and macOS will ask for your login password once after each update
> before Loquor can use your API key.
