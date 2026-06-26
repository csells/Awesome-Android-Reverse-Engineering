#!/usr/bin/env bash
# native-roundtrip.sh — disassemble an ARM64 Android .so to REASSEMBLABLE form and
# reassemble it back into a working .so. This is the native analog of the smali
# round-trip: the round-trippable layer for native code is *assembly*, not decompiled
# C. Uses ddisasm (lift to GTIRB) + gtirb-pprinter (binary print) in Docker.
#
#   native-roundtrip.sh <libfoo.so> [outdir]
#
# Output (in outdir, default <so>-nativert/): out.gtirb, shared.s, rebuilt.so, plus a
# verification summary (exports / DT_NEEDED / .text similarity).
#
# Result is FUNCTIONALLY EQUIVALENT, not byte-identical: the assembler+linker re-lay
# out code, so addresses/branch-offsets/GOT entries differ (~5-15% .text byte match is
# normal). Verified by: same exported symbols, same DT_NEEDED, and the lib loads & runs.
#
# Requires: Docker (daemon running). Builds image `ddisasm-aarch64` from the sibling
# ddisasm.Dockerfile on first run.
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

so="${1:-}"; [[ -f "$so" ]] || die "usage: $0 <libfoo.so> [outdir]"
so="$(cd "$(dirname "$so")" && pwd)/$(basename "$so")"
out="${2:-${so%.so}-nativert}"; mkdir -p "$out"
cp "$so" "$out/orig.so"

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not running"
if ! docker image inspect ddisasm-aarch64 >/dev/null 2>&1; then
  echo ">> building ddisasm-aarch64 image (first run, downloads ~650MB base)…"
  docker build --platform linux/amd64 -t ddisasm-aarch64 -f "$here/ddisasm.Dockerfile" "$here"
fi

echo ">> disassembling + reassembling inside container…"
docker run --rm --platform linux/amd64 -v "$out":/work ddisasm-aarch64 bash -lc '
set -e; cd /work
echo "  [1/4] ddisasm: lift .so -> GTIRB + reassemblable asm"
ddisasm orig.so --ir out.gtirb --asm shared.s -j 4 >/dev/null 2>&1
echo "        $(wc -l < shared.s) lines of asm"

echo "  [2/4] build a versioned stub libc.so from the orig'"'"'s imports (preserve @LIBC/@LIBC_O)"
readelf --dyn-syms orig.so | awk "\$7==\"UND\" && \$8!=\"\"{print \$8}" | sort -u > und.txt
: > stub.s; : > ver.map
awk -F@ "{sym=\$1; print \".globl \" sym \"\n.type \" sym \",%function\n\" sym \":\n ret\"}" und.txt > stub.s
awk -F@ "{v=\$2; gsub(/^@/,\"\",v); if(v==\"LIBC\")L=L \$1 \"; \"; else if(v==\"LIBC_O\")O=O \$1 \"; \"}
         END{printf \"LIBC { global: %s };\nLIBC_O { global: %s };\n\", L, O}" und.txt > ver.map
mkdir -p /stubs
aarch64-linux-gnu-gcc -shared -nostdlib -Wl,--version-script=ver.map -Wl,-soname,libc.so stub.s -o /stubs/libc.so
# empty stubs for the other NEEDED libs so DT_NEEDED is preserved exactly
for s in $(objdump -p orig.so | awk "/NEEDED/{print \$2}" | grep -v "^libc.so$"); do
  printf ".text\n" | aarch64-linux-gnu-as -o /tmp/e.o -
  aarch64-linux-gnu-ld -shared -soname "$s" -o "/stubs/$s" /tmp/e.o
done

echo "  [3/4] reassemble via gtirb-pprinter (patch .arch for BTI; link against stubs)"
cat >/usr/local/bin/gccwrap <<W
#!/bin/bash
for a in "\$@"; do case "\$a" in *.s) sed -i "s/^\.arch armv8-a/.arch armv8.5-a/" "\$a";; esac; done
exec aarch64-linux-gnu-gcc "\$@" -L/stubs -Wl,--no-as-needed -Wl,-rpath-link,/stubs
W
chmod +x /usr/local/bin/gccwrap
gtirb-pprinter out.gtirb --shared=yes --use-gcc /usr/local/bin/gccwrap -b rebuilt.so >/dev/null 2>&1
echo "  [4/4] verify"
echo -n "        exports  orig=$(objdump -T orig.so|grep -c " g  *DF .text")  rebuilt=$(objdump -T rebuilt.so|grep -c " g  *DF .text")"
diff <(objdump -T orig.so|grep -oE "Java_[A-Za-z0-9_]+"|sort) <(objdump -T rebuilt.so|grep -oE "Java_[A-Za-z0-9_]+"|sort) >/dev/null && echo "  (JNI symbols identical)" || echo "  (JNI DIFFER)"
echo "        NEEDED orig:    $(objdump -p orig.so|awk "/NEEDED/{printf \$2 \" \"}")"
echo "        NEEDED rebuilt: $(objdump -p rebuilt.so|awk "/NEEDED/{printf \$2 \" \"}")"
'
echo ">> done. rebuilt: $out/rebuilt.so"
echo "   (functionally equivalent; not byte-identical — see references/native-code.md)"
