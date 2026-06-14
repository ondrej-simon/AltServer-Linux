#!/usr/bin/env bash
# Re-sign an unsigned .ipa with a modern signer (rcodesign) using the EMPTY-password cert this
# fork's patched AltServer caches, then install it. Workaround for iOS 26 TXM rejecting
# AltServer-Linux's own signatures. See ../IOS26.md.
#
# Prereqs: run the patched AltServer once to provision (see IOS26.md step 1); rcodesign is fetched
# automatically; needs openssl, python3, unzip/zip, ideviceprovision, ideviceinstaller.
#
# Usage:  tools/ios26-resign.sh <unsigned.ipa> [path-to-AltServerData]
set -euo pipefail

IPA="${1:?usage: ios26-resign.sh <unsigned.ipa> [AltServerData dir]}"
DATADIR="${2:-AltServerData}"
RCVER="0.29.0"
WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT" signing.pem' EXIT

P12="$(ls "$DATADIR"/Certificates/*.p12 2>/dev/null | head -1 || true)"
[ -n "$P12" ] || { echo "!! no cached cert in $DATADIR/Certificates — run the patched AltServer first"; exit 1; }

echo "==> rcodesign $RCVER"
if ! command -v rcodesign >/dev/null 2>&1 && [ ! -x ./rcodesign ]; then
  base="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${RCVER}"
  asset="apple-codesign-${RCVER}-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL "$base/$asset" -o "$WORKROOT/rc.tgz"
  exp=$(curl -fsSL "$base/$asset.sha256" | awk '{print $1}'); got=$(sha256sum "$WORKROOT/rc.tgz" | awk '{print $1}')
  [ "$exp" = "$got" ] || { echo "!! rcodesign checksum mismatch"; exit 1; }
  tar xzf "$WORKROOT/rc.tgz" -C "$WORKROOT"
  cp "$(find "$WORKROOT" -name rcodesign -type f | head -1)" ./rcodesign && chmod +x ./rcodesign
fi
RC="$(command -v rcodesign || echo ./rcodesign)"

echo "==> unpack IPA + read its bundle id"
unzip -q "$IPA" -d "$WORKROOT/app"
APP="$(ls -d "$WORKROOT"/app/Payload/*.app)"
BASEID="$(python3 - "$APP/Info.plist" <<'PY'
import sys,plistlib; print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleIdentifier'])
PY
)"
echo "    base bundle id: $BASEID"

echo "==> pull the matching provisioning profile off the device"
rm -rf "$WORKROOT/profiles" && mkdir "$WORKROOT/profiles"
ideviceprovision copy "$WORKROOT/profiles" >/dev/null 2>&1 || true
PROFILE=""
for f in "$WORKROOT"/profiles/*.mobileprovision; do
  openssl smime -inform der -verify -noverify -in "$f" 2>/dev/null | grep -aq "$BASEID" && PROFILE="$f"
done
[ -n "$PROFILE" ] || { echo "!! no device profile matches $BASEID — run the patched AltServer first"; exit 1; }
echo "    profile: $(basename "$PROFILE")"

echo "==> derive entitlements + full app-id from the profile"
openssl smime -inform der -verify -noverify -in "$PROFILE" 2>/dev/null > "$WORKROOT/profile.plist"
APPID="$(python3 - "$WORKROOT/profile.plist" "$WORKROOT/ents.plist" <<'PY'
import sys,plistlib
p=plistlib.load(open(sys.argv[1],'rb')); ent=p['Entitlements']
plistlib.dump(ent, open(sys.argv[2],'wb'))
print(ent['application-identifier'].split('.',1)[1])
PY
)"
echo "    app-id: $APPID"

echo "==> set CFBundleIdentifier + embed profile"
python3 - "$APP/Info.plist" "$APPID" <<'PY'
import sys,plistlib
d=plistlib.load(open(sys.argv[1],'rb')); d['CFBundleIdentifier']=sys.argv[2]
plistlib.dump(d, open(sys.argv[1],'wb'))
PY
cp "$PROFILE" "$APP/embedded.mobileprovision"

echo "==> decrypt empty-password key -> PEM, then sign"
openssl pkcs12 -legacy -nomacver -in "$P12" -nodes -passin pass: -out signing.pem
grep -q 'BEGIN.*PRIVATE KEY' signing.pem || { echo "!! key not decrypted — is this the patched (empty-pw) cache?"; exit 1; }
"$RC" sign --pem-file signing.pem --entitlements-xml-file "$WORKROOT/ents.plist" "$APP"

echo "==> repackage + install"
OUT="${IPA%.ipa}-resigned.ipa"; rm -f "$OUT"
( cd "$WORKROOT/app" && zip -qr "$OLDPWD/$OUT" Payload )
ideviceinstaller install "$OUT" || ideviceinstaller -i "$OUT"
echo "DONE -> $OUT installed. Tap the app; it should launch on iOS 26."
