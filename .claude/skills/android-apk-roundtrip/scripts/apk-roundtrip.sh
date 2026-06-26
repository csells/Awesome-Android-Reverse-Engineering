#!/usr/bin/env bash
# apk-roundtrip.sh — decompile an APK to an editable form, let you edit it, and
# recompile it into an installable, signed APK.
#
# Whether it "worked" is decided by the tools in the pipeline: if apktool/aapt2
# recompile the edited tree cleanly and the signer produces a verified APK, the
# build is good. The real test of an EDIT is behavioral — install the result and
# run it. There is deliberately no re-decode "verify" step: diffing a rebuild
# against the original only re-tests apktool's own fidelity (a property of the
# tool, like a C compiler's, not of your work), so it tells you nothing useful.
#
# Subcommands:
#   decode    <app.apk> [workdir]     apktool d  -> <workdir>/decoded
#   build     [workdir]               apktool b  -> <workdir>/rebuilt-unsigned.apk
#   sign      <apk> [workdir]         zipalign + sign (v1/v2/v3) + signature check
#   roundtrip <app.apk> [workdir]     decode -> build -> sign (full run)
#   native    <app.apk> [func]        survey native .so libs (apktool can't decompile these)
#   sources   <app.apk> [workdir]     (re)generate best-effort Java+C reading views
#   doctor                            check dependencies, print install commands
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

find_ghidra_headless() {
  if [[ -n "${GHIDRA_HEADLESS:-}" && -x "$GHIDRA_HEADLESS" ]]; then echo "$GHIDRA_HEADLESS"; return; fi
  have analyzeHeadless && { command -v analyzeHeadless; return; }
  local c
  for c in \
    "${GHIDRA_HOME:-}/support/analyzeHeadless" \
    /opt/homebrew/Cellar/ghidra/*/libexec/support/analyzeHeadless \
    /usr/local/Cellar/ghidra/*/libexec/support/analyzeHeadless \
    /opt/ghidra/support/analyzeHeadless; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

ensure_apktool() { have apktool || die "apktool not found (brew install apktool)"; }

# Pick the richest single ABI dir to decompile (one ABI is representative — the others
# are the same source recompiled). $1 = a lib/ root.
pick_abi_dir() {
  local root="$1" a
  for a in arm64-v8a armeabi-v7a x86_64 x86; do
    [[ -d "$root/$a" ]] && { echo "$root/$a"; return; }
  done
  find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1
}

# Emit best-effort source views ALONGSIDE the smali/lib trees, for reading only:
#   decoded/best-effort-java/    jadx Java for the whole app  (peer to smali*)
#   decoded/best-effort-c/<abi>/ Ghidra (or radare2) C per .so (peer to lib/)
# These are NOT recompilable and NOT part of the rebuild — apktool ignores extra
# top-level dirs in the decoded tree, so they never reach the rebuilt APK. Best-effort:
# a missing tool or a decompiler error is reported, never fatal.
# $1 = apk path, $2 = decoded dir. Skip everything with ROUNDTRIP_SOURCES=0;
# skip just the (slow) C step with ROUNDTRIP_NATIVE_C=0; force an ABI with ROUNDTRIP_C_ABI.
gen_sources() {
  local apk="$1" dec="$2"
  [[ "${ROUNDTRIP_SOURCES:-1}" == "0" ]] && { echo ">> best-effort sources disabled (ROUNDTRIP_SOURCES=0)"; return 0; }

  # --- Java (jadx), peer to smali* ---
  if have jadx; then
    local jout="$dec/best-effort-java"
    echo ">> best-effort Java (jadx) -> $jout/sources/"
    rm -rf "$jout"
    jadx --no-res -d "$jout" "$apk" >/dev/null 2>&1 \
      || echo "   (jadx reported errors — partial Java emitted, which is normal)"
  else
    echo ">> skipping best-effort Java — jadx not installed (brew install jadx)"
  fi

  # --- C (Ghidra, else radare2), peer to lib/ ---
  [[ "${ROUNDTRIP_NATIVE_C:-1}" == "0" ]] && { echo ">> best-effort C disabled (ROUNDTRIP_NATIVE_C=0)"; return 0; }
  [[ -d "$dec/lib" ]] || return 0
  local abidir
  if [[ -n "${ROUNDTRIP_C_ABI:-}" && -d "$dec/lib/$ROUNDTRIP_C_ABI" ]]; then
    abidir="$dec/lib/$ROUNDTRIP_C_ABI"
  else
    abidir="$(pick_abi_dir "$dec/lib")"
  fi
  [[ -n "$abidir" && -d "$abidir" ]] || return 0
  local abi; abi="$(basename "$abidir")"
  local cout="$dec/best-effort-c/$abi"; mkdir -p "$cout"
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local gh so base
  if gh="$(find_ghidra_headless)"; then
    echo ">> best-effort C (Ghidra headless, $abi only) -> $cout/"
    local proj; proj="$(mktemp -d)"
    for so in "$abidir"/*.so; do
      [[ -f "$so" ]] || continue
      base="$(basename "$so")"
      echo "   decompiling $base … (slow; Ghidra analyzes then decompiles)"
      "$gh" "$proj" "ghp_$base" -import "$so" \
        -scriptPath "$here" -postScript DecompileToC.java "$cout/$base.c" \
        -deleteProject -analysisTimeoutPerFile 600 >/dev/null 2>&1 \
        || echo "      (Ghidra failed on $base — skipped)"
    done
    rm -rf "$proj"
  elif have r2; then
    echo ">> best-effort C (radare2 pseudo-C, $abi only; install Ghidra for better C) -> $cout/"
    for so in "$abidir"/*.so; do
      [[ -f "$so" ]] || continue
      base="$(basename "$so")"
      echo "   pseudo-decompiling $base …"
      { echo "// Best-effort pseudo-C (radare2 pdc) of $base — APPROXIMATE, not recompilable."
        echo "// Install Ghidra (brew install ghidra) and re-run '$0 sources <apk>' for better C."
        echo
        r2 -q -e scr.color=0 -A -c 'pdc @@f' "$so" 2>/dev/null
      } > "$cout/$base.c" || true
    done
  else
    echo ">> skipping best-effort C — neither Ghidra nor radare2 installed"
    rmdir "$cout" 2>/dev/null || true
  fi
}

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
  gen_sources "$apk" "$wd/decoded"
  echo ">> decoded. Edit smali/res under $wd/decoded, then: $0 build $wd"
  echo "   (read-only views: $wd/decoded/best-effort-java/, $wd/decoded/best-effort-c/)"
}

cmd_sources() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="$(workdir_for "$apk" "${2:-}")"
  [[ -d "$wd/decoded" ]] || die "no decoded tree at $wd/decoded (run decode first)"
  gen_sources "$apk" "$wd/decoded"
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

cmd_roundtrip() {
  local apk="$1"; [[ -f "$apk" ]] || die "no such apk: $apk"
  local wd; wd="$(workdir_for "$apk" "${2:-}")"
  cmd_decode "$apk" "$wd"
  cmd_build "$wd"
  cmd_sign "$wd/rebuilt-unsigned.apk" "$wd"
  local signed; signed="$(ls "$wd"/signed/*.apk 2>/dev/null | grep -iv idsig | head -1)"
  echo
  echo "=== recompile complete (apktool + signer exited clean) ==="
  echo "workdir:  $wd"
  echo "editable: $wd/decoded   (edit smali/res here, then: $0 build $wd && $0 sign $wd/rebuilt-unsigned.apk $wd)"
  echo "signed:   $signed"
  echo
  echo "The tools recompiled and signed cleanly. To confirm an EDIT actually took"
  echo "effect, install and run it (this is the only verification that matters):"
  echo "  pkg=\$(aapt2 dump badging \"$apk\" | sed -n \"s/.*package: name='\\([^']*\\)'.*/\\1/p\")"
  echo "  adb uninstall \"\$pkg\"; adb install \"$signed\""
  echo "  adb shell monkey -p \"\$pkg\" -c android.intent.category.LAUNCHER 1"
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
  else echo "  [optional] jadx         best-effort Java view (decoded/best-effort-java) — brew install jadx"; fi

  local gh
  if gh="$(find_ghidra_headless)"; then echo "  [ok]       ghidra       $gh"
  else echo "  [optional] ghidra       best-effort C for native libs (decoded/best-effort-c) — brew install ghidra"
       echo "                          (radare2 is used as a lower-quality fallback if Ghidra is absent)"; fi

  if have d2j-dex2jar; then echo "  [ok]       dex2jar      present"
  else echo "  [optional] dex2jar      DEX<->JAR helper — brew install dex2jar"; fi

  if have apkeep; then echo "  [ok]       apkeep       present"
  else echo "  [optional] apkeep       fetch APKs to test on — brew install apkeep"; fi

  echo
  if [[ $missing_required -eq 0 ]]; then
    echo "All REQUIRED tools present — decode / build / sign will work."
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
  sources)   cmd_sources "$@";;
  decode)    cmd_decode "$@";;
  build)     cmd_build "$@";;
  sign)      cmd_sign "$@";;
  roundtrip) cmd_roundtrip "$@";;
  *) cat >&2 <<EOF
usage: $0 <doctor|native|sources|decode|build|sign|roundtrip> ...
  doctor                          # check dependencies, print install commands
  native    <app.apk> [func]      # survey native .so libs + JNI symbols (apktool can't decompile these)
  sources   <app.apk> [workdir]   # (re)generate best-effort Java+C views in decoded/best-effort-*
  decode    <app.apk> [workdir]   # decode also auto-generates best-effort Java+C views
  build     [workdir]             # apktool b; a clean exit means the recompile succeeded
  sign      <apk> [workdir]       # zipalign + sign; a clean exit means the APK is installable
  roundtrip <app.apk> [workdir]   # full pipeline (decode -> build -> sign)

The build's success/failure is the toolchain's exit code; the test of an EDIT is
to install the signed APK and run it. There is no re-decode "verify" step.
EOF
     exit 2;;
esac
