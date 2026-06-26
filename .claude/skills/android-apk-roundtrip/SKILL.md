---
name: android-apk-roundtrip
description: >-
  Decompile an Android APK into a fully editable, recompilable form (smali +
  decoded resources), edit it, and rebuild it into an installable, signed APK
  that runs with your changes in place. Use this whenever the user wants to
  decompile, disassemble, reverse engineer, unpack, mod, patch, edit, rebuild,
  recompile, repackage, or re-sign an .apk (or .xapk/.apks) — including "edit the
  smali and rebuild", "patch an Android app and reinstall it", "make a modded
  APK", or "change a resource and recompile". Also use when diagnosing why a
  rebuilt APK won't build, sign, install, or run. Built around apktool, with
  jadx/dex2jar for source-level reading and uber-apk-signer / Android build-tools
  for signing.
---

# Android APK Round-Trip (decompile → edit → recompile → run)

This skill takes an APK apart into an editable form, lets you edit it, and puts it
back together into an installable APK that runs with your edits. It is the
modification pipeline (apktool/smali), not just the read-only analysis pipeline (jadx).

## How you know it worked

The signal of success is whether the **tools in the pipeline succeed or fail**, and
then whether the edited app runs. It is **not** a re-decode diff.

- `apktool b` (which drives the smali assembler and aapt2) either recompiles the
  edited tree into a DEX + resources or it errors out. A clean exit means your smali
  and resources are valid; an error points at the exact file/line to fix.
- `apksigner` / uber-apk-signer either produce a validly signed APK or they fail. A
  signed APK that the signer verifies is, by definition, installable.
- The real test of your **edit** is behavioral: install the rebuilt APK and run it.
  If it launches and your change is in effect, you're done. If it crashes or the
  change isn't there, you edited the wrong thing or broke the smali — fix and rebuild.

That is the whole verification story. **Do not** re-decode the rebuild and diff it
against the original to "prove" fidelity — that only re-tests whether apktool
round-trips, which is a property of the tool, not of your work. You trust the smali
assembler and aapt2 the way you trust a C compiler; their exit codes are the answer.

One honest caveat to state up front: a **bit-identical** APK is impossible. You don't
have the developer's private signing key (so the signature differs by definition), and
apktool re-emits the DEX/ZIP with its own layout. That doesn't matter — the goal is an
installable APK that runs with your edits, not a byte clone. Say this so the user who
asked to "recompile to the same binary" isn't misled, then deliver the working rebuild.

## The toolchain (already installed on this machine)

| Tool | Use |
|------|-----|
| `apktool` | decode DEX→smali + binary resources→text; rebuild back to APK |
| `jadx` / `jadx-gui` | read-only Java decompilation; auto-run on decode → `best-effort-java/` |
| `ghidra` (headless) | read-only C decompilation of native `.so`; auto-run → `best-effort-c/` |
| `d2j-dex2jar` (dex2jar) | DEX→JAR for use with Java decompilers; alt smali path |
| `uber-apk-signer.jar` | one-shot zipalign + sign (v1/v2/v3) + signature check, auto debug key |
| `apksigner`,`zipalign`,`aapt2` | Android build-tools; manual sign/align, apktool's aapt2 backend |
| `keytool` | generate a debug keystore if signing manually |

**On a fresh clone, run the dependency check first** — the tools above are installed
system-wide, not vendored in the repo, so a new machine needs them:

```bash
scripts/apk-roundtrip.sh doctor   # reports each dep (required vs optional) + exact install commands
```

If a tool is missing: `brew install apktool jadx dex2jar`; Android build-tools come
from the command-line tools SDK (`sdkmanager "build-tools;34.0.0"`); uber-apk-signer
is a release jar from github.com/patrickfav/uber-apk-signer (optional — signing falls
back to the SDK build-tools if it's absent). Build-tools live under
`$ANDROID_HOME/build-tools/<ver>/`.

## Use the bundled script — don't hand-run each step

The whole pipeline is repetitive and easy to get subtly wrong (forgetting to align
before signing). Use `scripts/apk-roundtrip.sh`, which auto-discovers build-tools and
the signer:

```bash
# full pipeline: decode → build → sign, into <apk>-work/
scripts/apk-roundtrip.sh roundtrip path/to/app.apk [workdir]

# or step by step (use this when the user wants to EDIT between decode and build):
scripts/apk-roundtrip.sh decode path/to/app.apk [workdir]   # -> workdir/decoded (+ best-effort views)
#   ... edit smali / res under workdir/decoded ...
scripts/apk-roundtrip.sh build  [workdir]                   # -> workdir/rebuilt-unsigned.apk
scripts/apk-roundtrip.sh sign   workdir/rebuilt-unsigned.apk [workdir]

# (re)generate just the read-only source views, e.g. after installing Ghidra:
scripts/apk-roundtrip.sh sources path/to/app.apk [workdir]  # -> decoded/best-effort-{java,c}/
```

`decode` (and therefore `roundtrip`) **automatically** emits two read-only, best-effort
source views next to the editable trees — see *Best-effort source views* below.

If `build` exits cleanly the recompile succeeded; if `sign` exits cleanly you have an
installable APK. Those exit codes are the build's pass/fail — then install and run it
to confirm your edit (see *Installing / running the result*). There is no `verify`
subcommand: re-decoding the rebuild and diffing it only re-tests apktool, not your work.

Env overrides if auto-discovery fails:
`BUILD_TOOLS=/path/to/build-tools/<ver>` and `UBER_SIGNER=/path/to/uber-apk-signer.jar`.

## Best-effort source views (read-only, auto-generated)

Smali and reassemblable asm are the *recompilable* forms, but they're hard to read. So
`decode` also drops two **best-effort, read-only** source trees as peers to the editable
trees inside `decoded/` (apktool ignores extra top-level dirs, so they never reach the
rebuilt APK — verified):

| Folder | Tool | Peer to | What it is |
|--------|------|---------|------------|
| `decoded/best-effort-java/sources/` | jadx | `smali*/` | Java reconstruction of the whole app |
| `decoded/best-effort-c/<abi>/*.so.c` | Ghidra headless (radare2 fallback) | `lib/<abi>/` | C reconstruction of each native lib |

These are **lossy reconstructions for reading only** — they do not compile and are not
part of the round-trip. The workflow is unchanged: read `best-effort-java/` to understand
logic, then make the real edit in the corresponding `.smali`; read `best-effort-c/` to
understand a native lib, then patch the `.so` itself or hook it at runtime.

Notes:
- C decompilation is the slow step. Only **one ABI** is decompiled (arm64-v8a preferred —
  the other ABIs are the same source recompiled). Ghidra analyzes then decompiles each
  lib, which can take minutes per lib.
- Env knobs: `ROUNDTRIP_SOURCES=0` skips both views; `ROUNDTRIP_NATIVE_C=0` skips just the
  slow C step; `ROUNDTRIP_C_ABI=armeabi-v7a` forces a specific ABI. Missing tools or
  decompiler errors are reported, never fatal — the round-trip still succeeds.
- Re-run after installing a better decompiler: `scripts/apk-roundtrip.sh sources app.apk`.

## Editing the decoded app

- **Code** lives as `.smali` under `smali/`, `smali_classes2/`, … (one tree per
  original DEX). Smali is the human-readable form of Dalvik bytecode. To *read* logic,
  open the auto-generated `decoded/best-effort-java/sources/` (jadx); then make the actual
  edit in the corresponding smali. Don't try to rebuild from jadx Java — it's lossy.
- **Resources** are decoded to text: `res/values/*.xml`, layouts, drawables, and
  `AndroidManifest.xml` are all editable directly. `resources.arsc` is regenerated by
  aapt2 on rebuild.
- **Native libs** (`lib/<abi>/*.so`) and **`assets/`** are copied **verbatim** — and
  this is a blind spot to call out, not a convenience. apktool does **not** decompile
  native code. If an app's real logic is in C/C++ (game AI engines, DRM, crypto,
  anti-tamper, codecs), it lives in these `.so` files as compiled ARM/x86 machine
  code, and the smali is just a thin JNI shell that calls into it. The round-trip
  preserves these libraries perfectly but tells you nothing about what's inside them.
  For a first read, `decode` auto-generates a best-effort C view at
  `decoded/best-effort-c/<abi>/*.so.c` (Ghidra). To go deeper, use a separate
  disassembler/decompiler — see `references/native-code.md` (objdump/radare2/Ghidra), or run
  `scripts/apk-roundtrip.sh native <app.apk>` to list the libs and dump their exported
  JNI symbols. Native code *can* also be round-tripped (decompile **and** recompile),
  but not via decompiled C (that's lossy/one-way) — the round-trippable layer is
  reassemblable disassembly: `scripts/native-roundtrip.sh libfoo.so` uses ddisasm +
  gtirb-pprinter to rebuild a working `.so` (functionally equivalent, not byte-identical).
  Editing a native `.so` and repackaging into the APK still round-trips too, but that
  edit is binary patching, not smali.
- After editing, run `build` then `sign`. If `apktool b` errors, the recompile failed
  and the message names the file/line; fix it and rebuild.

## Installing / running the result — this is the actual test

This is where you confirm the edit worked. A clean `build`/`sign` only means the tools
accepted the input; it does not prove your change does what you intended. Put it on a
device/emulator and look:

```bash
pkg=$(aapt2 dump badging app.apk | sed -n "s/.*package: name='\([^']*\)'.*/\1/p")
adb uninstall "$pkg"                      # the rebuild is debug-signed; a differently-
                                          # signed copy (e.g. Play Store) blocks the install
adb install workdir/signed/*-debugSigned.apk
adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1   # launch it
adb logcat -d | grep -iE 'fatal|androidruntime'                   # did it crash on start?
```

If it launches and your change is in effect, the round-trip succeeded. That — not a
re-decode diff — is the verification that matters. The rebuilt APK is signed with a
**debug** key, so it will not update a Play Store install of the same package; that's
why the `adb uninstall` comes first.

## Troubleshooting

For rebuild/aapt2 failures, install errors (`NO_CERTIFICATES`,
`UPDATE_INCOMPATIBLE`), framework-resource issues on system/OEM apps, split APKs
(.xapk/.apks), and obfuscation, read `references/troubleshooting.md`.
