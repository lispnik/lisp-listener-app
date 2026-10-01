# The listener on a phone, and in TestFlight

There is no Xcode project, so the pieces Xcode would make behind the scenes are
made by hand, once, in a browser. After that a phone build is `make ios-device`
and a TestFlight build is `make testflight`.

Signing is personal, so it lives in `local.mk`, which is not committed:

```make
# make ios-device: a development build for a connected phone
IOS_SIGNING_IDENTITY = Apple Development: Your Name (XXXXXXXXXX)
IOS_PROVISIONING_PROFILE = /path/to/a/development.mobileprovision
IOS_DEVELOPMENT_TEAM = TEAMID1234

# make ipa / make testflight
IOS_DISTRIBUTION_IDENTITY = Apple Distribution: Your Name (TEAMID1234)
IOS_DISTRIBUTION_PROFILE = /path/to/Lisp_Listener_App_Store.mobileprovision
ASC_KEY_ID = XXXXXXXXXX
ASC_ISSUER_ID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## On your own phone

The team's wildcard development profile (Xcode makes one, *iOS Team
Provisioning Profile: \**) covers `org.lispnik.lisp-listener`, so nothing need
be registered first:

```sh
make ios-device      # => build/iphoneos/Lisp Listener.app, signed
xcrun devicectl device install app --device <udid> "build/iphoneos/Lisp Listener.app"
```

The phone needs Developer Mode (Settings › Privacy & Security), and to be
unlocked while the app goes on.

## TestFlight: once

1. **Register the App ID.**
   [Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   › **+** › App IDs › App. Description `Lisp Listener`, Bundle ID **explicit**,
   `org.lispnik.lisp-listener`. No capabilities.

2. **Make an App Store profile.**
   [Profiles](https://developer.apple.com/account/resources/profiles/list)
   › **+** › Distribution › **App Store Connect** › App ID
   `org.lispnik.lisp-listener` › the Apple Distribution certificate › name it
   `Lisp Listener App Store` › Generate › Download, and point
   `IOS_DISTRIBUTION_PROFILE` in `local.mk` at it. It grants
   `beta-reports-active`, which is what lets a build be tested in TestFlight.

3. **Create the app in App Store Connect.**
   [Apps](https://appstoreconnect.apple.com/apps) › **+** › New App. iOS; name
   `Lisp Listener` (or whatever is free -- the store name need not match
   `CFBundleName`); bundle ID `org.lispnik.lisp-listener`; SKU `lisp-listener`.

4. **The API key and issuer.** The key's `.p8` goes in
   `~/.appstoreconnect/private_keys/`; its id is `ASC_KEY_ID`. The **Issuer
   ID** is above the list of keys under Users and Access › Integrations › App
   Store Connect API, and is `ASC_ISSUER_ID`.

## TestFlight: every build

```sh
make testflight              # build, check, validate, upload
make testflight BUILD=0.1.90 # a build number of your own
make ipa                     # just build/Lisp-Listener.ipa
```

The build is for the device alone (`LISP_LISTENER_DISTRIBUTION=1`), from a clean
`build/iphoneos`, numbered `0.1.<commits>` so it never goes backwards and says
which commit a tester holds. Before anything is sent, `tools/testflight.sh`
checks that the signature is an Apple Distribution one, carries
`beta-reports-active` and not `get-task-allow`; then `altool` validates and
uploads.

`CFBundleShortVersionString` stays `0.1.0`; raise `:bundle-short-version` in
`lisp-listener-ios.asd` when the app itself changes version.

Export compliance is already answered: `ITSAppUsesNonExemptEncryption` is false
in the plist.

## Then, in App Store Connect

Processing takes a few minutes, after which the build is under **TestFlight**.
Internal testers -- your own team -- can install it at once, with no review.
External testers need Beta App Review, and before that **App Privacy**
(everything is "Data Not Collected": the listener sends nothing anywhere) and
Test Information.

## If the upload is refused

- *"Invalid Code Signing Entitlements"* -- the profile is not for
  `org.lispnik.lisp-listener`, or is a development one.
- *"... does not include the beta-reports-active entitlement"* -- an Ad Hoc or
  Development profile. Make an App Store one (step 2).
- *"The bundle version must be higher ..."* -- commit, or pass `BUILD=`.
- *"No suitable application records were found"* -- step 3 is not done.
