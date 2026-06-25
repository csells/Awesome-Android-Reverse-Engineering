# cache/ — acquired tools, test APKs, and digested study notes

Local working cache built while completing the goal: acquire the reverse-engineering
toolchain from this awesome-list, digest the material, and build + test a skill that
decompiles an APK into a recompilable form.

```
cache/
├── tools/      uber-apk-signer.jar (other tools installed via Homebrew; see notes/TOOLS.md)
├── apks/       uk.co.aifactory.backgammonfree.apk  (Backgammon v4.41 / vc143, test target)
├── resources/  (reserved for downloaded reference material)
└── notes/
    ├── TOOLS.md             toolchain manifest + versions + the reproducibility reality
    ├── STUDY.md             digest of the decompile/recompile workflow from the list
    └── ROUNDTRIP-EVIDENCE.md verified round-trip results on the Backgammon APK
```

## Tools acquired (round-trip relevant subset of the awesome list)

Installed via Homebrew (system-wide): **apktool 3.0.2**, **jadx 1.5.5**,
**dex2jar 2.4**, **apkeep 1.0.0** (used to fetch the test APK from APKPure).
Bundled jar: **uber-apk-signer 1.3.0** in `tools/`. Android **build-tools 34.0.0 &
37.0.0** (apksigner/zipalign/aapt2) already present in the cmdline-tools SDK.

Scope note: the awesome list catalogs ~80 tools/resources spanning dynamic analysis
(Frida, Drozer), firmware (binwalk, FirmWire), malware ML, books, and CTFs. This cache
deliberately acquires the subset needed for the stated goal — **fully decompiling an
APK into a recompilable form** — rather than cloning every unrelated repo. The full
catalog remains in the repo's top-level `README.md`.

## The skill this produced

`.claude/skills/android-apk-roundtrip/` — a project-scoped skill (decode → edit →
recompile → sign → verify) with a bundled `scripts/apk-roundtrip.sh`. Validated
end-to-end on the Backgammon APK; see `notes/ROUNDTRIP-EVIDENCE.md`.
