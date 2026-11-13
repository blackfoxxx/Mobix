#!/usr/bin/env bash
# Static triage of an APK: manifest, secrets, decompiled source, native libs.
# Usage: static-scan.sh <path-to-apk>
set -uo pipefail
. "$(dirname "$0")/env.sh"
APK="${1:?usage: static-scan.sh <app.apk>}"
# Android app bundles always name the main split literally "base.apk", and
# target_pull always saves to apks/<pkg>/base.apk - so basename(APK) alone is
# "base" for every target, and every scan silently landed in the same
# loot/static-base, mixing one target's decompiled sources and leaked secrets
# into the next target's output (confirmed live: an app.Delivery scan turned
# up a prior target's FaceTec/Firebase strings mixed into its own apkleaks.txt
# and jadx/sources). Prefer the package-name parent directory instead.
PKGDIR=$(basename "$(dirname "$APK")")
if [ -n "$PKGDIR" ] && [ "$PKGDIR" != "." ] && [ "$PKGDIR" != "/" ]; then
  NAME="$PKGDIR"
else
  NAME=$(basename "$APK" .apk)
fi
OUT="$MP_LOOT/static-$NAME"; mkdir -p "$OUT"
echo "[*] output -> $OUT"

echo "=== apktool (manifest + resources) ==="
apktool d -f -o "$OUT/apktool" "$APK" >"$OUT/apktool.log" 2>&1 && echo "[+] decoded" || echo "[-] apktool failed, see $OUT/apktool.log"

if [ -f "$OUT/apktool/AndroidManifest.xml" ]; then
  echo "=== security-relevant manifest flags ==="
  grep -oE 'android:(debuggable|allowBackup|usesCleartextTraffic|networkSecurityConfig|exported)="[^"]*"' \
    "$OUT/apktool/AndroidManifest.xml" | sort | uniq -c | sort -rn | head -20
  echo "--- exported components ---"
  grep -oE '<(activity|service|receiver|provider)[^>]*android:exported="true"[^>]*>' \
    "$OUT/apktool/AndroidManifest.xml" | grep -oE 'android:name="[^"]*"' | head -30 > "$OUT/exported-components.txt"
  wc -l < "$OUT/exported-components.txt" | xargs echo "  exported:"
  echo "--- network security config ---"
  find "$OUT/apktool/res" -name "network_security_config*" -exec sh -c 'echo "  {}"; cat "{}"' \; 2>/dev/null | head -40
fi

echo "=== jadx (java source) ==="
# jadx has no force-overwrite flag equivalent to apktool's -f, and silently
# adds to whatever is already in -d rather than replacing it, so re-scanning
# the same target twice (or, before the NAME fix above, a different target
# entirely) accumulated stale decompiled classes here indefinitely.
rm -rf "$OUT/jadx"
jadx -d "$OUT/jadx" --no-res -q "$APK" >"$OUT/jadx.log" 2>&1
[ -d "$OUT/jadx/sources" ] && echo "[+] $(find "$OUT/jadx/sources" -name '*.java' | wc -l | tr -d ' ') java files" || echo "[-] jadx produced no sources"

echo "=== apkleaks (secrets/endpoints) ==="
rm -f "$OUT/apkleaks.txt"
apkleaks -f "$APK" -o "$OUT/apkleaks.txt" >/dev/null 2>&1 && { echo "[+] $OUT/apkleaks.txt"; head -40 "$OUT/apkleaks.txt"; } || echo "[-] apkleaks failed"

echo "=== pinning indicators in source ==="
if [ -d "$OUT/jadx/sources" ]; then
  grep -rlE "CertificatePinner|checkServerTrusted|TrustManager|sslSocketFactory|pinning|X509TrustManager|HostnameVerifier" \
    "$OUT/jadx/sources" 2>/dev/null | head -20 | tee "$OUT/pinning-hits.txt"
fi

echo "=== native libs ==="
unzip -l "$APK" 2>/dev/null | grep -oE 'lib/[^/]+/[^ ]+\.so' | sort -u | head -20

echo; echo "[*] done -> $OUT"
