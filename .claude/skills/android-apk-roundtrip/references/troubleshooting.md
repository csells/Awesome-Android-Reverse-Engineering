# APK round-trip troubleshooting

Read this when a decode, rebuild, sign, install, or verify step misbehaves.

## Rebuild (apktool b) failures

- **aapt2 resource errors** (e.g. "duplicate value", "resource not found"): the app
  may have resources aapt2 rejects on re-encode. Try forcing aapt2 explicitly
  (`apktool b --use-aapt2 decoded -o out.apk`) or a different build-tools version
  (older build-tools' aapt2 is sometimes more lenient). As a last resort, decode with
  `-r` (skip resources, keep original `resources.arsc`) when you only need to patch
  code: `apktool d -r app.apk`; the resources are then not editable but pass through
  intact.
- **"brut.androlib" / framework errors** on system or OEM apps: the app references a
  framework resource package apktool doesn't know. Install the device framework first:
  pull `/system/framework/framework-res.apk` (and any vendor framework) and run
  `apktool if framework-res.apk`, then decode/build again.
- **smali assembly errors after editing**: usually a malformed register/label edit.
  Re-read the offending `.smali`; check `.locals`/`.registers` counts and that any
  added instruction uses valid register numbers.
- **OutOfMemory on huge apps**: `export JAVA_OPTS="-Xmx4g"` (or apktool's `-J`).

## Signing & install failures

- `INSTALL_PARSE_FAILED_NO_CERTIFICATES`: the APK was not signed (or only zipaligned).
  Always sign after building. Use `apk-roundtrip.sh sign`.
- **Order matters**: `zipalign` must run BEFORE `apksigner` — v2+ signatures cover the
  aligned layout, so aligning afterward invalidates them. uber-apk-signer does this in
  the right order automatically.
- `INSTALL_FAILED_UPDATE_INCOMPATIBLE` / `signatures do not match`: a build of the same
  package signed with a different key is already installed (e.g. the Play Store copy).
  `adb uninstall <package>` first, then install the rebuilt APK.
- `INSTALL_FAILED_INVALID_APK` / minSdk errors: check `aapt2 dump badging` for
  `sdkVersion`; the device/emulator must satisfy `minSdkVersion`.
- **targetSdk 30+** requires an APK Signature Scheme v2+; `apksigner` adds v2/v3 by
  default, so don't pass `--v2-signing-enabled false`.

## Split APKs (.xapk / .apks / .apkm bundles)

These contain a base APK plus per-density/per-ABI/feature split APKs (and sometimes
OBB assets). To work with one:
1. Unzip the bundle (`unzip app.xapk -d bundle`).
2. Decode/edit/rebuild the **base** APK (`<package>.apk` or `base.apk`) as usual.
3. Re-sign **every** split with the **same** key (uber-apk-signer accepts a directory:
   `java -jar uber-apk-signer.jar -a bundle/`).
4. Install all of them together: `adb install-multiple bundle/*.apk`.
A single standalone APK (most older/simple apps) needs none of this.

## Obfuscation & "the Java is unreadable"

R8/ProGuard/DexGuard rename classes/methods to `a`, `b`, `IE`, … and may encrypt
strings. This does NOT block the round-trip — smali still assembles back exactly. It
only makes *understanding* harder. Aids from the awesome list:
- `jadx --deobf app.apk` applies heuristic renaming for readability.
- dex2jar + a Java decompiler (CFR/Procyon/JD-GUI) as a cross-check.
- For string decryption, dynamic tools (Frida/objection) or `simplify` /
  `TinySmaliEmulator` can help, but that's analysis, not part of rebuilding.

## "Did my edit work?" — the only check that matters

Don't re-decode the rebuilt APK and diff it against the original to "prove"
correctness — that re-tests apktool's fidelity (a property of the tool), not your
edit. The build's pass/fail is the toolchain's exit code; the edit's pass/fail is
behavioral:
- `apktool b` / `apksigner` exited cleanly → the input was valid and the APK is
  installable. An error names the exact file/line to fix.
- Install and launch the rebuilt APK (`adb install` + `adb shell monkey -p <pkg>
  -c android.intent.category.LAUNCHER 1`), then watch `adb logcat`. If it runs and
  your change is in effect, you're done.

A bit-identical APK is impossible anyway (you lack the developer's signing key, and
apktool re-emits the DEX/ZIP layout) — and it doesn't matter, because the goal is a
working rebuild, not a byte clone.
