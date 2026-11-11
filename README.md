# FALCON INTEGRITY FIX

Magisk / KernelSU / KernelSU Next / APatch module that fixes Play Integrity.
Works on Android 10 to 17.

## What it does

* Hooks the keystore with [TrickyStore OSS](https://github.com/beakthoven/TrickyStoreOSS)
  so hardware attestation uses a real certificate chain instead of a software one.
* Ships a working keybox, so the module is useful straight after install.
* Keeps the spoofed build fingerprint in sync with Google's current Pixel build.
* Spots apps that call the integrity API and hides the module from them.
* Optional Widevine L1 fix for unlocked Qualcomm devices.

Two separate modules are involved. This repository is the module itself.

| Module | ID | Purpose |
| --- | --- | --- |
| FALCON INTEGRITY FIX | `falcon_integrity_fix` | The module (this repository) |
| FALCON TRICKY | `falcon_tricky` | Web UI companion, installed by this module |

## Download

Releases are attached to this repository. The file is
`FALCONINTEGITY_FIX_V<version>.zip`. Flash it from your root manager, then
reboot.

## Source

Everything in this repository is open. The shell and JavaScript parts are plain
text and can be read directly.

### Third-party files that are shipped inside the ZIP

Magisk modules have to ship compiled files, so here is where each one comes
from and what its licence is.

| File in the ZIP | Upstream project | Licence |
| --- | --- | --- |
| `zygisk/arm64-v8a.so`, `zygisk/armeabi-v7a.so`, `zygisk/x86.so`, `zygisk/x86_64.so` | [PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork) (module `playintegrityfix`) | Apache-2.0 |
| `classes.dex` | same as above, the helper dex that reads `pif.json` | Apache-2.0 |
| `tricky/lib/<arch>/libTrickyStoreOSS.so`, `tricky/lib/<arch>/libinject.so` | [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS) | Apache-2.0 |
| `tricky/classes.dex` | [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS) | Apache-2.0 |
| `busybox` | [BusyBox](https://busybox.net) | GPL-2.0 |
| `falcon_tricky/webroot/**` | this repository | GPL-3.0 |

`lib/` (the TEE-Simulator libraries) is **not** part of this release. The
keystore engine used here is TrickyStoreOSS, which is what `tricky/` holds.

### Reproducing the build

The ZIP is produced by `build_zip.ps1` (PowerShell 5+). It stages the files
listed above, writes `payload.sha256` with one SHA-256 per file, then zips the
tree.

```powershell
.\build_zip.ps1
```

The upstream binaries are not rebuilt, they are copied from the upstream
releases:

* PlayIntegrityFork: <https://github.com/osm0sis/PlayIntegrityFork/releases>
* TrickyStoreOSS: <https://github.com/beakthoven/TrickyStoreOSS/releases>

## Layout

| Path | What it is |
| --- | --- |
| `module.prop` | module metadata, `id=falcon_integrity_fix` |
| `customize.sh` | installer: stages files, backs up and wipes `/data/adb/tricky_store`, forces the bundled keybox |
| `post-fs-data.sh` | early boot, before GMS starts |
| `service.sh` | main service, starts the keystore engine and refreshes the fingerprint |
| `action.sh` | the Action button, full refresh on demand |
| `kb_sync.sh` | keybox fetcher, checks Google's revocation list before installing |
| `falcon_keybox.sh` | manages the keybox slot and the copies kept under `/data/adb/falcon` |
| `falcon_tricky/` | the FALCON TRICKY Web UI, installed as its own module |
| `sepolicy.rule` | SELinux rules the keystore engine needs to read the module files |

## Keybox

`keybox.xml` is shipped inside the release ZIP and is not committed to this
repository on purpose, so the file stays in the release asset only.

On every install/update the module backs up and wipes `/data/adb/tricky_store`,
then forces the bundled keybox on both the active path and the primary slot.
A full copy of the old directory is kept in
`/data/adb/falcon/.slots/backups/`, together with the previous active keybox.
Boot does not overwrite a valid custom keybox; only an install/update forces
the bundled one.

To use your own keybox between updates, drop it in
`/data/adb/tricky_store/keybox.xml` and reboot. The module keeps the active
slot in `/data/adb/falcon/.token_cache`.

## Notes

* Needs a module manager that supports Zygisk (Magisk, KernelSU with
  ZygiskNext / ReZygisk / NeoZygisk, or APatch).
* PlayIntegrityFork is loaded from the `playintegrityfix` path, the module
  mirrors its files there on install.
* On Android 16 and newer the hardware attestation path changed, so the
  fingerprint that gets used there may still need a look.

## Licence

GPL-3.0 for the parts written here. The bundled third-party files keep their
own licences, listed in the table above.
