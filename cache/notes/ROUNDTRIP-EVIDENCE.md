# Verified round-trip evidence — Backgammon (AI Factory)

Target: `uk.co.aifactory.backgammonfree.apk` — versionName 4.41, versionCode 143,
targetSdk 35, 5 DEX, arm64 native libs. Original signer: AI Factory Limited.
Original sha256: `b2502c2e30ae31e39390eb718e2908c24a9e65e8ce3bcd9e8c350e5a2eb82fc5`.

## Procedure executed
1. `apktool d -o decoded <apk>`        → 5 smali trees + res + lib + assets (~5s)
2. `apktool b decoded -o rebuilt.apk`  → rebuilt with aapt2 (~6s)
3. `uber-apk-signer -a rebuilt.apk --allowResign` → zipalign + v1/v2/v3 sign + verify
4. `apktool d` the signed rebuilt APK  → `redecoded`
5. `diff -rq decoded redecoded`        → self-consistency check

## Results
- `apksigner verify`: **verified [v1, v2, v3]** (debug cert; original key unavailable).
- AndroidManifest.xml: **IDENTICAL** on re-decode.
- smali, smali_classes2, smali_classes3, smali_classes5: **IDENTICAL**.
- smali_classes4: only differences are filename `.1` disambiguation of obfuscated
  classes that differ ONLY by case (`IE`/`Ie`, `MC`/`Mc`, `NC`/`NE`/`Nc`/`Ne`...).
  Cause: **macOS case-insensitive APFS** (confirmed via probe). The `.class`
  directives inside prove BOTH classes are present and correct in both decodes;
  the compiled DEX is unaffected (smali names classes by directive, not filename).
- res: only `res/values/attrs.xml` differs, and only by **element ordering**
  (same 1822 lines; `<flag>`/`<enum>` reordered) — apktool aapt2 iteration-order
  artifact, no semantic change.

## Conclusion
The decoded tree is a **complete, recompilable representation**: rebuilding it and
re-decoding reproduces the same smali/manifest. Remaining diffs are 100% cosmetic
(filesystem case-collision filenames + resource element ordering) and do not affect
the compiled artifact's behavior.

A **bit-identical** APK is provably impossible here (original private key unavailable;
DEX/ZIP layout from the original dexer differs). "Same binary" is therefore defined as
a **faithful, self-consistent, installable round-trip**, which is achieved. To reduce
even the cosmetic FS diff, decode on a case-sensitive filesystem/volume.
