# AltServer-Linux on iOS 26 (this fork)

Upstream AltServer-Linux installs apps on **iOS 26.4+** that **crash instantly on launch** (blank
icon, no crash report), and with stricter signing they fail to install at all. The cause is ldid's
code signature, which iOS 26's kernel **TXM (Trusted Execution Monitor)** rejects. Upstream tracking
issue: <https://github.com/NyaMisty/AltServer-Linux/issues/131>.

**This fork fixes it by signing apps with [`rcodesign`](https://github.com/indygreg/apple-platform-rs)
instead of ldid.** AltServer still does everything else (Apple auth, certificate, provisioning
profile, install) — only the signing step is swapped. Result: apps **install and launch directly on
iOS 26**, no extra steps.

> Confirmed on iPhone 15 Pro, iOS 26.5: `Installation Succeeded`, app launches.

## Why ldid doesn't work on iOS 26

ldid (vendored at ~2022) diverges from modern `codesign` in several places that iOS 26 now enforces:

- **DER entitlements** emitted as a bare ASN.1 `SET` instead of Apple's `[APPLICATION 16] { INTEGER
  version, [CONTEXT 16] { … } }` schema (and DER booleans as `0x01` instead of `0xFF`).
- A legacy **SHA-1-primary CodeDirectory** (hash agility) instead of **SHA-256-only**.
- **Empty designated requirements** on the app and every framework.
- An older **CodeResources** resource-sealing format.

You can bring ldid most of the way (DER + SHA-256 CD + a DR generator make the Mach-O signatures
byte-identical to rcodesign), but CodeResources — and likely more — still diverge. Rather than
re-implement modern `codesign` inside ldid, this fork uses rcodesign, which already does it all
correctly. (An RFC3161 timestamp is **not** required for development installs.)

## What the fix changes

A single build-time edit in `makefiles/AltSign-build/rewrite_altsign_source.py`: in AltSign's
`Signer::SignApp`, the `ldid::Sign(...)` call is replaced with a shell-out to
`rcodesign sign --pem-file <key> --entitlements-xml-file <ents> <app>`. The bundle is already
prepared by AltSign (provisioning profile embedded, per-app entitlements computed), and
`CertificatesContent` already builds an empty-password p12 with the leaf + WWDR + Apple Root chain;
we convert that to PEM with `openssl` and hand it to rcodesign. The submodule and ldid are untouched.

## Requirements (on the Linux host that runs AltServer)

- **`rcodesign`** (apple-codesign) — download a release from
  <https://github.com/indygreg/apple-platform-rs/releases>. Point `ALTSERVER_RCODESIGN` at it (or put
  it on `PATH`).
- **`openssl`**, plus the usual `libimobiledevice` / `usbmuxd`, and an **anisette** server.

## Build

```bash
docker run --rm -v "$PWD":/workdir -w /workdir \
  ghcr.io/nyamisty/altserver_builder_alpine_amd64 \
  bash -c 'mkdir -p build && cd build && (make -f ../Makefile -j"$(nproc)" || make -f ../Makefile -j1)'
# -> build/AltServer-x86_64   (use the arm/i386 builder image for other arches)
```

## Use

```bash
ALTSERVER_RCODESIGN="/path/to/rcodesign" \
ALTSERVER_ANISETTE_SERVER="http://localhost:6969" \
  ./AltServer-x86_64 -u <UDID> -a <apple-id> -p '<password>' YourApp.ipa
```

It authenticates (enter the 2FA code when prompted), provisions a cert + profile, signs the bundle
with rcodesign (you'll see `rcodesign signing: …`), and installs — `Installation Succeeded`, and the
app launches. A **free** Apple ID's signature lasts 7 days; re-run to refresh.
