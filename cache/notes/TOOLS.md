# Cached Reverse-Engineering Toolchain

Environment captured on host: macOS (darwin 25.5), Apple Silicon, Homebrew at /opt/homebrew.

## Installed / verified tools

| Tool | Version | Path / invocation | Role in round-trip |
|------|---------|-------------------|--------------------|
| Java (OpenJDK) | 21.0.11 (+ 26.0.1 pulled as apktool dep) | `/usr/bin/java` | Runs apktool/jadx/signer jars |
| apktool | 3.0.2 | `apktool` (brew) | Decompile (`d`) → smali+resources; rebuild (`b`) |
| jadx | 1.5.5 | `jadx`, `jadx-gui` (brew) | Read-only Java decompilation (analysis, not rebuild) |
| dex2jar | 2.4 | `d2j-dex2jar`, `d2j-baksmali`, ... (brew) | DEX↔JAR, alt smali path |
| uber-apk-signer | 1.3.0 | `java -jar cache/tools/uber-apk-signer.jar` | One-shot zipalign + sign + verify |
| apksigner | 0.9 (build-tools 34.0.0 / 37.0.0) | SDK build-tools | v1–v4 APK signing + verify |
| zipalign | (build-tools) | SDK build-tools | 4-byte alignment of APK |
| aapt2 | 2.19 | SDK build-tools | Resource packaging (apktool backend) |
| adb | 1.0.41 | `/opt/homebrew/bin/adb` | Pull installed APKs, install test build |
| keytool | JDK | `/usr/bin/keytool` | Generate debug keystore |
| radare2 | (brew) | `r2`, `rabin2` | **Native** `.so` disassembly + pseudo-decompile (`pdc`) |
| Ghidra | 12.1.2 | `ghidraRun`, `analyzeHeadless` | **Native** ARM64/x86 → C decompiler (headless via `GhidraDecompile.java`) |
| objdump / nm / c++filt | system | `/usr/bin/objdump` | ELF symbols / demangle C++ names in `.so` |

**Native code note:** apktool does NOT decompile `lib/<abi>/*.so`. App logic in C/C++
(e.g. the Backgammon AI engine) needs the bottom three tools — separate from the
smali round-trip. See the skill's `references/native-code.md`.

Android SDK: `/opt/homebrew/share/android-commandlinetools` (ANDROID_HOME).
Build-tools available: **34.0.0** and **37.0.0**. Add to PATH:
`export PATH="$ANDROID_HOME/build-tools/34.0.0:$PATH"`

## The reproducibility reality (important)

"Recompile to produce the SAME binary" with Android has a hard limit: a **bit-identical
APK is not achievable** from a decompile, because:
- The original is signed with the developer's **private key**, which we do not have. Any
  rebuild must be re-signed with a different key → different signature block + cert.
- apktool rebuilds DEX from smali; smali→DEX is deterministic for instructions but the
  original DEX may have been produced by a different dexer (d8/dx) with different layout,
  string-pool ordering, and debug info. Bytes can differ even when semantics match.
- ZIP container metadata (timestamps, compression level, file ordering) differs.

So the achievable, correct definition of success is a **faithful round-trip**:
1. `apktool d` → editable smali + resources.
2. `apktool b` → a rebuilt APK that is **functionally equivalent** to the original.
3. zipalign + sign → an installable APK whose **smali/resources re-decompile identically**
   to the rebuilt tree (self-consistent round-trip), and which installs & runs.

Verification we CAN do deterministically:
- Re-decompile the rebuilt APK and `diff` the smali trees → should be identical
  (proves the decompiled form fully captures the code, i.e. it is a true recompilable form).
- Compare `apktool`-normalized resource trees of original vs rebuilt.
- `apksigner verify` passes; `adb install` succeeds; app launches.

This nuance is baked into the skill so users aren't misled by "identical binary" claims.
