# Study digest — Android APK decompile/recompile round-trip

Distilled from the Awesome-Android-Reverse-Engineering list (apktool, jadx, dex2jar,
uber-apk-signer, Android build-tools) and validated hands-on against a real app.

## The two distinct goals (don't conflate them)
- **Read the code** (analysis): `jadx` / `dex2jar`+JD → Java source. Lossy, NOT rebuildable.
- **Edit & rebuild** (modification): `apktool` → smali + decoded resources → rebuild.
  This is the only path that round-trips back to an installable APK.

## apktool pipeline
- `apktool d <apk> -o out` decodes DEX→smali (via baksmali) and binary XML/arsc→text.
- `apktool b out -o new.apk` reassembles: smali→DEX (smali), resources→arsc (aapt2).
- Key flags: `-s` (skip smali, keep original DEX), `-r` (skip resources), `-f` (force
  overwrite), `--use-aapt2` (default in 3.x), `--only-main-classes`. Framework files for
  decoding system/OEM apps: `apktool if framework.apk`.

## Signing (always required after rebuild)
A rebuilt APK is unsigned; Android refuses to install unsigned APKs.
- One-shot: `uber-apk-signer -a rebuilt.apk` (auto zipalign + v1/v2/v3 + verify, debug key).
- Manual: `zipalign -p 4 in.apk aligned.apk` then `apksigner sign --ks key.jks aligned.apk`.
- ORDER MATTERS: zipalign BEFORE apksigner (v2+ signatures cover alignment).
- You cannot reuse the original developer key → resigned APK has a different cert. It will
  NOT update the Play Store install (signature mismatch); uninstall original first to test.

## Reproducibility ceiling
Bit-identical rebuild is impossible without the original private key AND original dexer/zip
toolchain. Achievable + verifiable success = **self-consistent round-trip**: re-decode the
rebuilt APK, diff smali/manifest against the first decode → should match. Expect only
cosmetic diffs from (1) case-insensitive filesystems collapsing case-distinct obfuscated
class filenames, and (2) resource element ordering in attrs/styleables.

## Common rebuild pitfalls
- Build fails on aapt2 resource errors → try `apktool b --use-aapt2` explicitly or older
  build-tools; some apps need `apktool if` for a custom framework.
- Forgetting to zipalign/sign → `INSTALL_PARSE_FAILED_NO_CERTIFICATES`.
- Editing then hitting `INSTALL_FAILED_UPDATE_INCOMPATIBLE` → different signer than installed
  build; `adb uninstall <pkg>` first.
- targetSdk 30+ needs v2+ signature (apksigner default handles this).
- Native `.so` libs and `assets/` are copied verbatim by apktool — untouched, safe.
