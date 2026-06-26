# Reverse-engineering native libraries (`lib/<abi>/*.so`)

Read this when the app's real logic isn't in the smali — game AI engines, DRM,
licensing, crypto, anti-tamper/root checks, custom codecs are routinely shipped as
compiled C/C++ in `.so` files. **apktool copies these verbatim and does not
decompile them.** The smali is usually just a JNI shell that calls in. The round-trip
skill preserves the libs perfectly but is blind to their contents; this is a separate
discipline (machine-code RE), with separate tools.

## Triage with what's usually already there

```bash
# Which ABIs / libs exist (apktool leaves them under decoded/lib/<abi>/):
find decoded/lib -name '*.so'

# Is it stripped? What architecture? (BuildID, ELF type)
file libfoo.so

# Exported symbols — the public API. For C++ the mangled names reveal the whole
# class/method structure even when debug info is stripped; JNI entry points are the
# Java<->native boundary:
objdump -T libfoo.so | grep -E ' g  *DF .text'      # exported functions
objdump -T libfoo.so | grep -oE 'Java_[A-Za-z0-9_]+'  # JNI methods
c++filt _ZN7MyClass8MyMethodEi                        # demangle a C++ name
```

`objdump` and `nm` ship with the system toolchain. `c++filt` demangles C++ symbols.

## Best-effort C is already generated for you

`decode`/`roundtrip` auto-decompile one ABI's `.so` files to C at
`decoded/best-effort-c/<abi>/<lib>.so.c` using **Ghidra headless** (the bundled
`scripts/DecompileToC.java` post-script decompiles every function), falling back to
radare2 `pdc` if Ghidra is absent. That C is a **lossy, read-only reconstruction** — it
does not recompile. Re-generate it after installing Ghidra with
`scripts/apk-roundtrip.sh sources app.apk`. Everything below is for going deeper than
that first-pass view.

## Disassemble + decompile

The skill bundles a `native` subcommand for the survey step:

```bash
scripts/apk-roundtrip.sh native app.apk            # list libs + dump JNI symbols
scripts/apk-roundtrip.sh native app.apk 0x3e39c    # pseudo-decompile a function (radare2)
```

Tool tiers (from the awesome list), lightest to heaviest:

- **radare2** (`brew install radare2`) — fast disassembly + a built-in pseudo-decompiler:
  ```bash
  r2 -A libfoo.so
  > afl                 # list analyzed functions
  > s sym.Java_...      # seek to a symbol (r2 DEMANGLES C++ names — seek by address if a
  > s 0x3e39c           #   mangled-name seek misses)
  > pdf                 # disassemble the function
  > pdc                 # pseudo-C decompile
  ```
- **Ghidra** (`brew install ghidra`) — the awesome-list's headline free decompiler;
  far better C output. Use it headless to batch-decompile a lib to C:
  ```bash
  # the bundled post-script (also used by `sources`) writes every function to one .c:
  analyzeHeadless /tmp/ghproj proj -import libfoo.so \
    -scriptPath scripts -postScript DecompileToC.java out.c -deleteProject
  # or open the GUI: ghidraRun, import the .so, auto-analyze, read the Decompile pane.
  ```
- **IDA Pro / Hex-Rays** — commercial, best-in-class; same idea.

## Round-tripping native code: decompile AND recompile a `.so`

Decompiled C does **not** rebuild (it's a lossy reconstruction — won't compile, and a
compiler would emit different code). But native binaries *do* have a round-trippable
layer, exactly like smali is for DEX: **reassemblable disassembly** (assembly ⇄ binary).
The tool is **ddisasm** (GrammaTech's Datalog disassembler) → GTIRB IR, then
**gtirb-pprinter** prints assembly and links it back into a working binary.

One command (bundled): `scripts/native-roundtrip.sh libfoo.so [outdir]` →
`outdir/rebuilt.so`. It runs ddisasm + gtirb-pprinter in Docker (image built from
`ddisasm.Dockerfile`). What it does and the gotchas it handles, in order:

1. `ddisasm orig.so --ir out.gtirb --asm shared.s` — lift to reassemblable asm
   (a ~280 KB engine lifts to ~200k lines).
2. `gtirb-pprinter out.gtirb --shared=yes --use-gcc <wrapper> -b rebuilt.so` —
   reassemble + link. Three things that otherwise break an ARM64 Android `.so`:
   - **BTI**: ddisasm emits `bti` instructions but hardcodes `.arch armv8-a`, which the
     assembler rejects. Fix: a tiny gcc wrapper that rewrites it to `.arch armv8.5-a`.
   - **Missing dependency libs**: the cross-sysroot has no Android `libc.so` etc. Build
     a **stub `libc.so` from the original's own undefined symbols**, preserving exact
     version nodes (`@LIBC`, `@LIBC_O` — bionic put `operator delete` / `__cxa_pure_virtual`
     in libc under `LIBC_O`). Empty stubs for the other NEEDED libs keep `DT_NEEDED` exact.
   - Link `-Wl,--no-as-needed` so all original `DT_NEEDED` entries are recorded.

**Verification (what "same" means for native — it is NOT byte-identity):** the
assembler/linker re-lay out code, so addresses, branch offsets and GOT entries all
shift — expect only ~5–15% of `.text` bytes to match. Equivalence is shown structurally
and behaviourally instead:
- same exported function count + **identical JNI symbol set**,
- **identical `DT_NEEDED`**,
- the rebuilt `.so` **loads and runs**. (Verified end-to-end on a real published game's
  native engine: swapped the reassembled lib into its APK, rebuilt/signed/installed;
  Android's nativeloader logged the lib loaded `: ok` and the app ran with no crash.)

Alternative linker: instead of the stub-libc trick you can link on a host that has the
**Android NDK** sysroot (`clang --target=aarch64-linux-androidNN -nostartfiles -shared`),
which already ships versioned bionic stub libs — but match the API level to the symbols
(`operator delete@LIBC_O` needs API ≥ 26).

## Editing native code (rare, but it round-trips)

You can patch a `.so` (radare2 write mode `r2 -w`, or a hex editor) and the apktool
round-trip will repackage it fine — it's just a file in `lib/`. But this is **binary
patching** (find the instruction, change the bytes/branch), not smali editing, and
the result must remain a valid ELF. For most "change the behavior" tasks it's easier
to hook at runtime with **Frida** (also in the awesome list) than to statically patch.
