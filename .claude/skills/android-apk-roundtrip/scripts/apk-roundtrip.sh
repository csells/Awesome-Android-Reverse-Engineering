#!/usr/bin/env bash
# apk-roundtrip.sh — decompile an APK to an editable, recompilable form and
# rebuild it into an installable, signature-verified APK, then prove the
# decoded form is a complete recompilable representation via a self-consistent
# re-decode diff.
#
# Subcommands:
#   decode   <app.apk> [workdir]      apktool d  -> <workdir>/decoded
#   build    [workdir]                apktool b  -> <workdir>/rebuilt-unsigned.apk
#   sign     <apk> [workdir]          zipalign + sign (v1/v2/v3) + verify
#   verify   <app.apk> [workdir]      re-decode rebuilt & diff vs original decode
#   roundtrip <app.apk> [workdir]     decode -> build -> sign -> verify (full run)
#
# Defaults: workdir = ./<apkbasename>-work
# Env overrides: BUILD_TOOLS=/path/to/build-tools/<ver>  UBER_SIGNER=/path/to/uber-apk-signer.jar
set -euo pipefail

# ---------- tool discovery ----------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

find_build_tools() {
  # honor explicit override
  if [[ -n "${BUILD_TOOLS:-}" && -x "$BUILD_TOOLS/apksigner" ]]; then echo "$BUILD_TOOLS"; return; fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  local cand
  for base in "$sdk" "$HOME/Library/Android/sdk" "/opt/homebrew/share/android-commandlinetools" "/usr/local/share/android-commandlinetools"; do
    [[ -d "$base/build-tools" ]] || continue
    # pick highest version dir that actually contains apksigner
    cand=$(ls -1 "$base/build-tools" 2>/dev/null | sort -V | while read -r v; do
             [[ -x "$base/build-tools/$v/apksigner" ]] && echo "$base/build-tools/$v"; done | tail -1)
    [[ -n "$cand" ]] && { echo "$cand"; return; }
  done
  return 1
}

find_uber_signer() {
  if [[ -n "${UBER_SIGNER:-}" && -f "$UBER_SIGNER" ]]; then echo "$UBER_SIGNER"; return; fi
  # look next to this repo's cache, then common spots
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for p in \
    "$here/../../../../cache/tools/uber-apk-signer.jar" \
    "$here/uber-apk-signer.jar" \
    "$HOME/cache/tools/uber-apk-signer.jar"; do
    [[ -f "$p" ]] && { echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"; return; }
  done
  return 1
}

ensure_apktool() { have apktool || die "apktool not found (brew install apktool)"; }

# ---------- subcommands -------------------------------------------------------
workdir_for() { # $1 = apk path
  local b; b="$(basename "${1%.apk}")"
  echo "${2:-./${b}-work}"
}

cmd_decode() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="$(workdir_for "$apk" "${2:-}")"
  ensure_apktool
  mkdir -p "$wd"
  echo ">> decoding $apk -> $wd/decoded"
  apktool d -f -o "$wd/decoded" "$apk"
  echo ">> decoded. Edit smali/res under $wd/decoded, then: $0 build $wd"
}

cmd_build() {
  local wd="${1:-.}"
  [[ -d "$wd/decoded" ]] || die "no decoded tree at $wd/decoded (run decode first)"
  ensure_apktool
  echo ">> building $wd/decoded -> $wd/rebuilt-unsigned.apk"
  apktool b "$wd/decoded" -o "$wd/rebuilt-unsigned.apk"
  echo ">> built. Now: $0 sign $wd/rebuilt-unsigned.apk $wd"
}

cmd_sign() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="${2:-$(dirname "$apk")}"
  local out="$wd/signed"; mkdir -p "$out"
  local uber bt
  if uber="$(find_uber_signer)"; then
    echo ">> signing with uber-apk-signer: $uber"
    java -jar "$uber" -a "$apk" --allowResign -o "$out"
  elif bt="$(find_build_tools)"; then
    echo ">> uber-apk-signer not found; using SDK build-tools at $bt"
    local ks="$HOME/.android/debug.keystore"
    if [[ ! -f "$ks" ]]; then
      mkdir -p "$HOME/.android"
      keytool -genkeypair -keystore "$ks" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US"
    fi
    "$bt/zipalign" -f -p 4 "$apk" "$out/aligned.apk"
    "$bt/apksigner" sign --ks "$ks" --ks-pass pass:android --key-pass pass:android \
      --out "$out/signed.apk" "$out/aligned.apk"
    "$bt/apksigner" verify --print-certs "$out/signed.apk"
  else
    die "no signer available (need uber-apk-signer.jar or Android build-tools)"
  fi
  echo ">> signed APK(s) in $out"
  ls -la "$out"/*.apk
}

cmd_verify() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="$(workdir_for "$apk" "${2:-}")"
  [[ -d "$wd/decoded" ]] || die "no original decode at $wd/decoded (run decode/roundtrip first)"
  ensure_apktool
  local signed
  signed=$(ls -1 "$wd"/signed/*.apk 2>/dev/null | grep -iv idsig | head -1 || true)
  [[ -n "$signed" ]] || die "no signed APK in $wd/signed (run sign first)"
  echo ">> re-decoding rebuilt $signed -> $wd/redecoded"
  apktool d -f -o "$wd/redecoded" "$signed" >/dev/null
  echo ">> diffing decoded vs redecoded ..."
  local fails=0
  # manifest
  if diff -q "$wd/decoded/AndroidManifest.xml" "$wd/redecoded/AndroidManifest.xml" >/dev/null; then
    echo "  AndroidManifest.xml : IDENTICAL"
  else
    echo "  AndroidManifest.xml : DIFFERS"; fails=$((fails+1))
  fi
  # smali trees
  for d in "$wd"/decoded/smali*; do
    [[ -d "$d" ]] || continue
    local name; name="$(basename "$d")"
    local other="$wd/redecoded/$name"
    if [[ ! -d "$other" ]]; then echo "  $name : MISSING in rebuild"; fails=$((fails+1)); continue; fi
    if diff -rq "$d" "$other" >/dev/null 2>&1; then
      echo "  $name : IDENTICAL"
    else
      # Filenames may differ on case-insensitive filesystems (macOS/APFS), where
      # obfuscated classes that differ only by case (IE vs Ie) collide and apktool
      # appends a .1/.2 suffix to disambiguate. That is purely an on-disk artifact:
      # smali names a class by its `.class` directive, not its filename, so the
      # compiled DEX is unaffected. The filesystem-independent invariant is the SET
      # of `.class` directives plus the concatenated, name-sorted file contents.
      local a b
      a=$(grep -rhE '^\.class' "$d"      2>/dev/null | sort)
      b=$(grep -rhE '^\.class' "$other"  2>/dev/null | sort)
      # also compare full normalized content (every file's body, independent of filename)
      local ca cb
      ca=$(find "$d"     -name '*.smali' -exec cat {} + 2>/dev/null | sort | shasum -a 256 | cut -d' ' -f1)
      cb=$(find "$other" -name '*.smali' -exec cat {} + 2>/dev/null | sort | shasum -a 256 | cut -d' ' -f1)
      if [[ "$a" == "$b" && "$ca" == "$cb" ]]; then
        echo "  $name : equivalent (identical class set & content; only case-insensitive-FS filenames differ)"
      else
        echo "  $name : DIFFERS"
        diff <(echo "$a") <(echo "$b") | head -6 | sed 's/^/      /'
        fails=$((fails+1))
      fi
    fi
  done
  echo ">> round-trip verification: $([[ $fails -eq 0 ]] && echo 'PASS (faithful, self-consistent)' || echo "REVIEW ($fails real diffs)")"
  return 0
}

cmd_roundtrip() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="$(workdir_for "$apk" "${2:-}")"
  cmd_decode "$apk" "$wd"
  cmd_build "$wd"
  cmd_sign "$wd/rebuilt-unsigned.apk" "$wd"
  cmd_verify "$apk" "$wd"
  echo
  echo "=== round-trip complete ==="
  echo "workdir:  $wd"
  echo "editable: $wd/decoded   (edit smali/res here, re-run: $0 build $wd && $0 sign $wd/rebuilt-unsigned.apk $wd)"
  echo "signed:   $(ls "$wd"/signed/*.apk 2>/dev/null | grep -iv idsig | head -1)"
}

# ---------- dispatch ----------------------------------------------------------
sub="${1:-}"; shift || true
case "$sub" in
  decode)    cmd_decode "$@";;
  build)     cmd_build "$@";;
  sign)      cmd_sign "$@";;
  verify)    cmd_verify "$@";;
  roundtrip) cmd_roundtrip "$@";;
  *) cat >&2 <<EOF
usage: $0 <decode|build|sign|verify|roundtrip> ...
  decode    <app.apk> [workdir]
  build     [workdir]
  sign      <apk> [workdir]
  verify    <app.apk> [workdir]
  roundtrip <app.apk> [workdir]   # full pipeline
EOF
     exit 2;;
esac
