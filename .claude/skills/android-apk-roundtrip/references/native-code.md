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
c++filt _ZN17CBackgammonEngine18Bg_BoardEvaluationEv  # demangle a C++ name
```

`objdump` and `nm` ship with the system toolchain. `c++filt` demangles C++ symbols.

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
  analyzeHeadless /tmp/ghproj proj -import libfoo.so \
    -postScript DecompileToC.java -deleteProject
  # or open the GUI: ghidraRun, import the .so, auto-analyze, read the Decompile pane.
  ```
- **IDA Pro / Hex-Rays** — commercial, best-in-class; same idea.

## Editing native code (rare, but it round-trips)

You can patch a `.so` (radare2 write mode `r2 -w`, or a hex editor) and the apktool
round-trip will repackage it fine — it's just a file in `lib/`. But this is **binary
patching** (find the instruction, change the bytes/branch), not smali editing, and
the result must remain a valid ELF. For most "change the behavior" tasks it's easier
to hook at runtime with **Frida** (also in the awesome list) than to statically patch.

## Worked example in this repo

`decompiled/backgammon/native/` reverse-engineers `libbackgammonfree-engine.so` (the
Backgammon AI): `README.md` maps the engine's classes (`CBackgammonEngine`,
`CFireball`, `CCharacterProfile`) and JNI surface; `engine-pseudocode.txt` is the
radare2 pseudo-decompile of the five core AI functions, including the weighted-sum
board evaluation heuristic.
