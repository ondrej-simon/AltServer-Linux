# AltServer-Linux on iOS 26 (this fork)

On **iOS 26.4 and later**, apps sideloaded with upstream AltServer-Linux **install but crash the
instant you launch them** — blank icon, a brief flash, no error, and **no crash report**. This is a
stale code-signing implementation in AltServer-Linux, not a problem with the app you're installing.

This fork adds a small change so you can get apps running on iOS 26 from Linux today, by re-signing
with a modern signer ([`rcodesign`](https://github.com/indygreg/apple-platform-rs)).

Upstream tracking issue: <https://github.com/NyaMisty/AltServer-Linux/issues/131>.

## Why it breaks

iOS 26 enforces code signatures in the kernel via **TXM (Trusted Execution Monitor)**. Capture the
device log while tapping the app (`idevicesyslog`) and you'll see, at every launch:

```
kernel  TXM [Error]: CodeSignature: selector: 24 | 0x53 | 0x23 | 9
SpringBoard(FrontBoard)  [app<…>:-1] Now flagged as pending exit for reason: Bootstrap failed
```

AMFI (user space) **accepts the provisioning profile** (`AMFI: profile validated the code signature`),
but the kernel's TXM rejects the **signature encoding** AltServer-Linux produces, so the process is
killed at `exec` (`pid -1`) before any code runs. Apple's AltServer for Windows/macOS fixed this in
**v1.7.4** by updating its code-signing library; that fix hasn't been ported to AltServer-Linux
(latest release v0.0.5). The same bug blocks **SideStore** on Linux, since its installer
(`SideStore/Altcon`) downloads this same AltServer-Linux to sign `SideStore.ipa`.

## What this fork changes

A one-line change in `makefiles/rewrite_altserver_source.py`: AltServer is made to cache its signing
key with an **empty p12 password** (`encryptedP12Data(*machineIdentifier)` → `encryptedP12Data("")`).
Upstream encrypts that cache with the certificate's `machineId` — a random UUID generated at
cert-creation time (`AltSign/AppleAPI.cpp`: `{ "machineId", make_uuid() }`), sent to Apple and
**never stored locally** — which makes the signing key impossible to reuse offline. With the empty
password, you can decrypt the key and re-sign the app with `rcodesign`, whose signature iOS 26 accepts.

The actual signature AltServer-Linux emits is left untouched; this fork is a pragmatic re-sign
workaround, not a fix to the bundled `ldid`. The proper fix is to port v1.7.4's code-signing update.

## Build

Use the project's own Alpine/musl Docker builder (no toolchain setup needed):

```bash
docker run --rm -v "$PWD":/workdir -w /workdir \
  ghcr.io/nyamisty/altserver_builder_alpine_amd64 \
  bash -c 'mkdir -p build && cd build && make -f ../Makefile -j"$(nproc)"'
# -> build/AltServer-x86_64   (use the arm/i386 builder image for other arches)
```

## Use it

You need a local **anisette** server and **rcodesign**, plus `libimobiledevice` /
`ideviceinstaller` on the host.

1. **Provision once** with the patched binary (mints a cert cached with an empty password and pushes
   a provisioning profile to the device). Delete any old cached cert first so a fresh one is minted:

   ```bash
   rm -f AltServerData/Certificates/*.p12
   ALTSERVER_ANISETTE_SERVER="http://localhost:6969" \
     ./build/AltServer-x86_64 -u <UDID> -a <apple-id> -p '<password>' YourApp.ipa
   ```

   Its own install still crashes on launch — **ignore that**. You only need the empty-password cert
   it just cached and the profile it pushed to the device.

2. **Re-sign with rcodesign and install** — either run [`tools/ios26-resign.sh YourApp.ipa`](tools/ios26-resign.sh),
   or do it by hand:

   ```bash
   # key out of the empty-password cache (RC2-40 + OpenSSL-3 empty-pw MAC quirk -> -legacy -nomacver)
   openssl pkcs12 -legacy -nomacver -in AltServerData/Certificates/*.p12 -nodes -passin pass: -out key.pem
   # current profile + its entitlements
   ideviceprovision copy ./profiles
   #  -> pick profiles/<uuid>.mobileprovision for your app; decode its Entitlements to ents.plist,
   #     set the app's CFBundleIdentifier to the profile's application-identifier (minus the team prefix),
   #     and copy the profile into the bundle as embedded.mobileprovision
   rcodesign sign --pem-file key.pem --entitlements-xml-file ents.plist YourApp.app
   # repackage to .ipa and install
   ideviceinstaller install YourApp-resigned.ipa
   ```

   The app launches. ✅ (Confirmed on iPhone 15 Pro, iOS 26.5.)

## Notes

- A free Apple ID's signature/profile lasts **7 days** — re-run both steps to refresh.
- Re-using the **same bundle id** avoids the free account's 10-App-IDs-per-7-days limit.
- Run your **own** anisette server; public ones tend to get your Apple ID rate-limited.
