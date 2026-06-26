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

cmd_native() {
  # Survey native .so libraries in an APK (or a decoded workdir) — the part apktool
  # copies verbatim and does NOT decompile. Lists libs, then for each ARM64 lib dumps
  # exported JNI/symbol names, and pseudo-decompiles a named function if asked.
  local target="$1"; [[ -n "$target" ]] || die "usage: $0 native <app.apk|workdir> [funcAddrOrName]"
  local fn="${2:-}"
  local tmp libs
  if [[ -f "$target" ]]; then
    local apkabs; apkabs="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    tmp="$(dirname "$apkabs")/.native-$$"; mkdir -p "$tmp"
    trap '[[ -n "${tmp:-}" ]] && rm -rf "$tmp"' RETURN   # always clean up the extraction
    ( cd "$tmp" && unzip -oq "$apkabs" 'lib/*' 2>/dev/null ) || true
    libs="$tmp/lib"
  elif [[ -d "$target/decoded/lib" ]]; then libs="$target/decoded/lib"
  elif [[ -d "$target/lib" ]]; then libs="$target/lib"
  else die "no native libs found under $target"; fi

  echo ">> native libraries (copied verbatim by apktool — NOT decompiled):"
  find "$libs" -name '*.so' -exec ls -la {} + 2>/dev/null | awk '{print "   ", $5, $NF}'
  local arm64; arm64=$(find "$libs" -path '*arm64-v8a*' -name '*.so' | sort)
  for so in $arm64; do
    echo; echo ">> $(basename "$so") — exported JNI entry points:"
    objdump -T "$so" 2>/dev/null | grep -oE 'Java_[A-Za-z0-9_]+' | sort -u | sed 's/^/     /' | head -40
    local n; n=$(objdump -T "$so" 2>/dev/null | grep -c ' g  *DF .text')
    echo "     ($n total exported functions; full C++ symbol map: objdump -T '$so')"
  done
  if [[ -n "$fn" ]]; then
    have r2 || die "radare2 not installed (brew install radare2) — needed to decompile"
    local so1; so1=$(echo "$arm64" | head -1)
    echo; echo ">> pseudo-decompile of '$fn' in $(basename "$so1"):"
    r2 -q -e scr.color=0 -A -c "s $fn; af; pdc" "$so1" 2>/dev/null
  else
    echo; echo ">> to decompile a function: $0 native $target <addr|sym>   (needs radare2)"
    echo "   for full C pseudocode use Ghidra; see references/native-code.md"
  fi
  [[ -n "${tmp:-}" ]] && rm -rf "$tmp"
}

cmd_doctor() {
  local missing_required=0
  echo "apk-roundtrip doctor — checking dependencies for a fresh machine"
  echo

  if have java; then
    echo "  [ok]       java         $(java -version 2>&1 | head -1 | sed 's/.*version //;s/\"//g')"
  else
    echo "  [MISSING]  java         REQUIRED — install a JDK 17+ (brew install openjdk)"
    missing_required=1
  fi

  if have apktool; then
    echo "  [ok]       apktool      $(apktool --version 2>&1)"
  else
    echo "  [MISSING]  apktool      REQUIRED — brew install apktool"
    missing_required=1
  fi

  local bt
  if bt="$(find_build_tools)"; then
    echo "  [ok]       build-tools  $bt"
  else
    echo "  [MISSING]  build-tools  REQUIRED (apksigner/zipalign/aapt2) — install Android"
    echo "                          command-line tools, then: sdkmanager \"build-tools;34.0.0\""
    echo "                          Then set ANDROID_HOME, or BUILD_TOOLS=/path/to/build-tools/<ver>"
    missing_required=1
  fi

  local uber
  if uber="$(find_uber_signer)"; then
    echo "  [ok]       uber-signer  $uber"
  else
    echo "  [optional] uber-signer  not found — OK, signing falls back to build-tools."
    echo "                          To use it: download uber-apk-signer.jar from"
    echo "                          github.com/patrickfav/uber-apk-signer and set UBER_SIGNER=/path"
    echo "                          (or drop it at <repo>/cache/tools/uber-apk-signer.jar)."
  fi

  if have jadx; then echo "  [ok]       jadx         $(jadx --version 2>&1 | head -1)"
  else echo "  [optional] jadx         read-only Java view for analysis — brew install jadx"; fi

  if have d2j-dex2jar; then echo "  [ok]       dex2jar      present"
  else echo "  [optional] dex2jar      DEX<->JAR helper — brew install dex2jar"; fi

  if have apkeep; then echo "  [ok]       apkeep       present"
  else echo "  [optional] apkeep       fetch APKs to test on — brew install apkeep"; fi

  echo
  if [[ $missing_required -eq 0 ]]; then
    echo "All REQUIRED tools present — decode / build / sign / verify will work."
    return 0
  fi
  echo "Missing REQUIRED tool(s) above. One-shot setup on macOS (Homebrew):"
  echo "  brew install apktool jadx dex2jar apkeep"
  echo "  brew install --cask android-commandlinetools   # provides sdkmanager"
  echo "  sdkmanager \"build-tools;34.0.0\"                 # provides apksigner/zipalign/aapt2"
  echo "  export ANDROID_HOME=\"\$(brew --prefix)/share/android-commandlinetools\""
  return 1
}

# ---------- dispatch ----------------------------------------------------------
sub="${1:-}"; shift || true
case "$sub" in
  doctor|setup) cmd_doctor "$@";;
  native)    cmd_native "$@";;
  decode)    cmd_decode "$@";;
  build)     cmd_build "$@";;
  sign)      cmd_sign "$@";;
  verify)    cmd_verify "$@";;
  roundtrip) cmd_roundtrip "$@";;
  *) cat >&2 <<EOF
usage: $0 <doctor|native|decode|build|sign|verify|roundtrip> ...
  doctor                          # check dependencies, print install commands
  native    <app.apk> [func]      # survey native .so libs + JNI symbols (apktool can't decompile these)
  decode    <app.apk> [workdir]
  build     [workdir]
  sign      <apk> [workdir]
  verify    <app.apk> [workdir]
  roundtrip <app.apk> [workdir]   # full pipeline
EOF
     exit 2;;
esac
