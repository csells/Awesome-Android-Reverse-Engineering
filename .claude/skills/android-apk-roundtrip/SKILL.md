---
name: android-apk-roundtrip
description: >-
  Decompile an Android APK into a fully editable, recompilable form (smali +
  decoded resources) and rebuild it into an installable, signature-verified APK,
  with a round-trip reproducibility check proving the decoded form is a complete
  recompilable representation. Use this whenever the user wants to decompile,
  disassemble, reverse engineer, unpack, mod, patch, edit, rebuild, recompile,
  repackage, or re-sign an .apk (or .xapk/.apks) — including "decompile this APK
  so it can be recompiled to the same binary", "edit the smali and rebuild",
  "patch an Android app and reinstall it", "make a modded APK", or "verify an APK
  round-trips". Also use when comparing an original vs rebuilt APK or diagnosing
  why a rebuilt APK won't install. Built around apktool, with jadx/dex2jar for
  source-level reading and uber-apk-signer / Android build-tools for signing.
---

# Android APK Round-Trip (decompile → edit → recompile → verify)

This skill takes an APK apart into an editable form, puts it back together into an
installable APK, and proves the round-trip is faithful. It is the modification
pipeline (apktool/smali), not just the read-only analysis pipeline (jadx).

## First, set expectations honestly: what "same binary" really means

A user asking to "recompile to the same binary" is usually picturing a bit-for-bit
identical APK. **That is not achievable and you should say so up front**, because:

- The original APK is signed with the **developer's private key**, which you do not
  have. Any rebuild must be re-signed with a different key → the signing block and
  certificate differ by definition.
- apktool reassembles DEX from smali. smali→DEX is faithful to the *instructions*,
  but the original DEX was emitted by the developer's dexer (d8/R8) with its own
  string-pool ordering, layout, and debug info. The ZIP container also re-packs with
  different timestamps/compression/ordering. So the bytes differ even when behavior
  is identical.

What **is** achievable, and what this skill delivers, is a **faithful, self-consistent,
installable round-trip**: the decoded tree is a *complete recompilable representation*
of the app — rebuild it, re-decode the rebuild, and you get back the same smali and
manifest. Verifiable success criteria:

1. `apksigner verify` passes on the rebuilt APK (v1/v2/v3).
2. Re-decoding the rebuilt APK yields **identical** smali class set + content and an
   identical AndroidManifest vs the original decode.
3. The rebuilt APK installs and the app runs.

Lead with this framing so the user isn't misled, then deliver the round-trip.

## The toolchain (already installed on this machine)

| Tool | Use |
|------|-----|
| `apktool` | decode DEX→smali + binary resources→text; rebuild back to APK |
| `jadx` / `jadx-gui` | read-only Java decompilation for understanding code (not rebuildable) |
| `d2j-dex2jar` (dex2jar) | DEX→JAR for use with Java decompilers; alt smali path |
| `uber-apk-signer.jar` | one-shot zipalign + sign (v1/v2/v3) + verify, auto debug key |
| `apksigner`,`zipalign`,`aapt2` | Android build-tools; manual sign/align, apktool's aapt2 backend |
| `keytool` | generate a debug keystore if signing manually |

If a tool is missing: `brew install apktool jadx dex2jar`; Android build-tools come
from the command-line tools SDK (`sdkmanager "build-tools;34.0.0"`); uber-apk-signer
is a release jar from github.com/patrickfav/uber-apk-signer. Build-tools live under
`$ANDROID_HOME/build-tools/<ver>/`.

## Use the bundled script — don't hand-run each step

The whole pipeline is repetitive and easy to get subtly wrong (forgetting to align
before signing, diffing the wrong trees). Use `scripts/apk-roundtrip.sh`, which
auto-discovers build-tools and the signer:

```bash
# full pipeline: decode → build → sign → verify, into <apk>-work/
scripts/apk-roundtrip.sh roundtrip path/to/app.apk [workdir]

# or step by step (use this when the user wants to EDIT between decode and build):
scripts/apk-roundtrip.sh decode path/to/app.apk [workdir]   # -> workdir/decoded
#   ... edit smali / res under workdir/decoded ...
scripts/apk-roundtrip.sh build  [workdir]                   # -> workdir/rebuilt-unsigned.apk
scripts/apk-roundtrip.sh sign   workdir/rebuilt-unsigned.apk [workdir]
scripts/apk-roundtrip.sh verify path/to/app.apk [workdir]   # re-decode + diff vs original
```

`verify` compares the original decode against a re-decode of the rebuilt APK. It
reports `IDENTICAL`, or `equivalent` when the only differences are case-insensitive
filesystem filename suffixes (see below) — confirmed by matching the full `.class`
directive set and concatenated smali content, which are filename-independent.

Env overrides if auto-discovery fails:
`BUILD_TOOLS=/path/to/build-tools/<ver>` and `UBER_SIGNER=/path/to/uber-apk-signer.jar`.

## Editing the decoded app

- **Code** lives as `.smali` under `smali/`, `smali_classes2/`, … (one tree per
  original DEX). Smali is the human-readable form of Dalvik bytecode. To *read* logic
  it's far easier to also run `jadx app.apk` and read the Java; then make the actual
  edit in the corresponding smali. Don't try to rebuild from jadx Java — it's lossy.
- **Resources** are decoded to text: `res/values/*.xml`, layouts, drawables, and
  `AndroidManifest.xml` are all editable directly. `resources.arsc` is regenerated by
  aapt2 on rebuild.
- **Native libs** (`lib/<abi>/*.so`) and **`assets/`** are copied verbatim and left
  untouched — safe to leave alone unless you specifically target them.
- After editing, run `build` then `sign`. To confirm a change landed, inspect the
  rebuilt APK, e.g. `aapt2 dump badging signed.apk` for manifest/label changes.

## Installing / running the result

- The rebuilt APK is signed with a **debug** key, so it will NOT update a Play Store
  install of the same package (signature mismatch). To test on a device/emulator:
  `adb uninstall <package>` first, then `adb install workdir/signed/*-debugSigned.apk`.
- Get the package name with `aapt2 dump badging app.apk | grep package`.

## The case-insensitive-filesystem caveat (macOS)

On macOS (APFS, case-insensitive by default), obfuscated classes whose names differ
only by case — e.g. `IE` and `Ie` — map to the same filename, so apktool writes one as
`IE.smali` and the colliding one as `IE.1.smali`. Which member gets the `.1` suffix can
flip on re-decode, producing filename-only diffs. This is cosmetic: the `.class`
directive inside each file carries the true class name, so the compiled DEX is correct.
The `verify` step accounts for this. To eliminate even the cosmetic diff, decode on a
**case-sensitive** volume (e.g. a case-sensitive APFS disk image).

## Troubleshooting

For rebuild/aapt2 failures, install errors (`NO_CERTIFICATES`,
`UPDATE_INCOMPATIBLE`), framework-resource issues on system/OEM apps, split APKs
(.xapk/.apks), and obfuscation, read `references/troubleshooting.md`.
