# RoMa Matcher v2 Compose

AutoUpdater deploy package for the **RoMa v2 matcher**: the same `roma-matcher` service and the same
HTTP API as the v1 package ([`roma-matcher-compose`](https://github.com/modelingevolution/roma-matcher-compose)),
but matching with RoMa v2 (`romav2==2.0.1`, preset `base`) on the **full frame**. rw2 needs no change:
both packages serve on `127.0.0.1:7662`, and a station runs one of them at a time.

Owner request (2026-11-08): "prepare roma_v2 base image for rw2 in autoupdater. Same api. added as a
separate autoupdater entry - like roma_v1." Owner ruling (2026-11-08): "the best results are with full
frame - not cropped. So we're talking only about that." — v2 is full frame only.

The service (Dockerfiles, wire contract, source) lives in
[`roma-matcher`](https://github.com/modelingevolution/roma-matcher); the v2 image is built there from
the same Dockerfiles with `--build-arg ROMA_VARIANT=v2`. This repo only deploys the pre-built
multi-arch image — it never builds.

## Why v2 (measured)

Jetson Orin NX, 24 Nabor operator-corrected cases, median error / time per match:

| Matcher | Median error | Time per match |
|---|---|---|
| **v2 base, full frame** (this package) | **2.7 px** | **1.30 s** |
| v1 production (640 px crop) | 4.9 px | 4.72 s |
| v1 full frame | 4.2 px | 4.92 s |
| v2 base, 640 px crop | 5.4 px | — |

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Base service: pinned Harbor image, `runtime: nvidia`, `ROMA_*` env, loopback port `127.0.0.1:7662`, `/health` healthcheck, json-file logging. No `build`, no `depends_on`. |
| `docker-compose.x64.yml` | x86_64 override — `platform: linux/amd64`. AutoUpdater layers it on `uname -m` = `x86_64`. |
| `docker-compose.arm64.yml` | ARM64 override — `platform: linux/arm64`. AutoUpdater layers it on `uname -m` = `aarch64`. |
| `roma-matcher-v2.version` | Bare semver of the pinned release (`0.0.0` = nothing released yet). |
| `update-version.sh` | `set X.Y.Z` pins the image tag across base + overrides and writes the version file; `list` queries Harbor for available `roma-matcher-v2` release tags. |
| `release.sh` | Pins the version, commits + pushes master, then creates + pushes the git tag AutoUpdater detects. |

## Service contract

| Aspect | Value |
|---|---|
| Service / container | `roma-matcher-v2` (compose project `roma-matcher-v2`; v1 is `roma-matcher`) |
| Image | `docker.modelingevolution.com/roma-matcher/roma-matcher-v2:<pinned tag>` — one multi-arch manifest (amd64 + arm64), pulled, never built |
| Backend | Image defaults `ROMA_MODEL=v2`, `ROMA_V2_SETTING=base`, `ROMA_CROP_WINDOW_PX=0` (full frame; a per-request `crop_size` is ignored in v2) |
| GPU | `runtime: nvidia`; `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility` |
| Weights | Baked into the image as a torch hub cache (`TORCH_HOME=/models`): `hub/checkpoints/romav2.0.1.pt` + `hub/facebookresearch_dinov3_adc2544…/`. Loads offline. No v1 weights in this image. |
| Ports | `127.0.0.1:7662:7662` — loopback-only; the same port as the v1 package, so only one of them can be up (see switching) |
| Debug dumps | `/var/docker/data/roma-matcher-v2/match-dumps` |
| Healthcheck | `python3 -c urllib` on `/health`; interval 30s, timeout 10s, retries 3, start_period 180s |
| Restart | `unless-stopped` |

Validate the resolved config anywhere (no GPU needed):

```bash
docker compose -f docker-compose.yml -f docker-compose.x64.yml config
```

## One matcher at a time — switching v1 ⇄ v2

Owner ruling (2026-11-08): "We won't run v1 and v2 in parallel. But we will switch them - turn on one
while the other is off." Both packages publish host port **7662**, so rw2's `RomaMatcher:BaseAddress`
stays `http://127.0.0.1:7662` for both and switching needs no rw2 change. The shared port also makes
running both by accident impossible: the second `up` fails with "port is already allocated" (on a
16 GB Jetson both together OOM — measured 2026-11-08, v2 next to v1 OOM-killed v1).

AutoUpdater has **no per-package on/off** (its API is `packages`, `status`, `update`, `update-all`,
`create`/`restore` backups — checked in `modelingevolution/autoupdater` `src/`). So a switch is a
`docker compose stop` of one package and `up -d` of the other, run in the packages' AutoUpdater
checkouts (`/data/<package>`), with the same arch override AutoUpdater uses:

```bash
ARCH=$( [ "$(uname -m)" = "aarch64" ] && echo arm64 || echo x64 )

# v1 -> v2
(cd /data/roma-matcher    && docker compose -f docker-compose.yml -f docker-compose.$ARCH.yml stop)
(cd /data/roma-matcher-v2 && docker compose -f docker-compose.yml -f docker-compose.$ARCH.yml up -d)

# v2 -> v1
(cd /data/roma-matcher-v2 && docker compose -f docker-compose.yml -f docker-compose.$ARCH.yml stop)
(cd /data/roma-matcher    && docker compose -f docker-compose.yml -f docker-compose.$ARCH.yml up -d)

# check: exactly one matcher answers on 7662
docker ps --filter name=roma-matcher --format '{{.Names}} {{.Status}}'
curl -s http://127.0.0.1:7662/health
```

A stopped container stays stopped across reboots (`restart: unless-stopped`). An AutoUpdater update of
the package that is OFF (`update <it>` or `update-all` when it has a new tag) runs `up -d` and fails
on port 7662 while the other one is on (inferred from the shared port, not yet observed); update the
package that is ON, or switch first.

## AutoUpdater registration (per station — not automatic)

The v1 package was registered fleet-wide on every NVIDIA device by the AutoUpdater self-update
migration `up-1.0.79.sh` in `autoupdater-compose`, which calls `add-package.sh`. **v2 has no such
migration**: the owner names the stations. On a chosen station, from the AutoUpdater install
directory (the `autoupdater-compose` checkout):

```bash
# 1. Register v2 as its own Packages[] entry (RepositoryLocation /data/roma-matcher-v2) in
#    /var/docker/configuration/autoupdater/appsettings.Production.json — idempotent; the v1 entry stays:
./add-package.sh roma-matcher-v2 https://github.com/modelingevolution/roma-matcher-v2-compose.git

# 2. Restart AutoUpdater so it reads the new entry; check it is listed:
docker restart autoupdater
./autoupdater.sh packages

# 3. Turn v1 off, then let AutoUpdater clone + deploy v2 (it runs `up -d` on 7662):
ARCH=$( [ "$(uname -m)" = "aarch64" ] && echo arm64 || echo x64 )
(cd /data/roma-matcher && docker compose -f docker-compose.yml -f docker-compose.$ARCH.yml stop)
./autoupdater.sh update roma-matcher-v2
```

After that, switch with the commands above. The resulting entry is the same shape as the v1 one:

```json
{
  "Packages": [
    {
      "RepositoryUrl": "https://github.com/modelingevolution/roma-matcher-v2-compose.git",
      "RepositoryLocation": "/data/roma-matcher-v2",
      "DockerComposeDirectory": "./"
    }
  ]
}
```

AutoUpdater clones `RepositoryUrl` to `RepositoryLocation`, detects the newest git tag, selects the arch
override by `uname -m`, then `pull` → `down` → `up -d` with
`-f docker-compose.yml -f docker-compose.<arch>.yml`.

## Release flow

| # | Stage | Trigger | Produces |
|---|---|---|---|
| 1 | CI build | push to `roma-matcher` master | `roma-matcher-v2:latest` + `roma-matcher-v2:master-<sha>` multi-arch manifest on Harbor (next to the v1 `roma-matcher` image, same run) |
| 2 | Promote | manual **Promote Release** on `roma-matcher` with `image = roma-matcher-v2` | release manifest `roma-matcher-v2:X.Y.Z` (digest re-tag; v2 has its own X.Y.Z line) |
| 3 | Compose release | developer, this repo | version bump committed + pushed to master, then a git tag |
| 4 | Deploy | AutoUpdater on a registered station detects the new tag | `pull` → `down` → `up -d` |

```bash
HARBOR_USERNAME='robot$roma-matcher+deploy-pull' HARBOR_PASSWORD='<secret>' \
  ./update-version.sh list      # roma-matcher-v2 release tags on Harbor — release only one that exists
./release.sh 0.0.1              # pin 0.0.1, commit + push master, tag v0.0.1
./release.sh --dry-run          # preview without changing anything
```

## Weights and licences

The image bakes two files from the Harbor OCI artifact `docker.modelingevolution.com/roma-matcher/weights:v2`
(staged by CI with `oras`, sha256-checked):

- `romav2.0.1.pt` — RoMa v2 checkpoint (sha256 `1557dec0…28b7`), from the RoMa v2 release.
- `dinov3-hub-adc2544.tar.gz` — the DINOv3 code at commit `adc2544…` that RoMa v2 loads via `torch.hub`.

**DINOv3 is distributed under Meta's DINOv3 License** (not an open-source licence; see `LICENSE.md` in
the baked `facebookresearch_dinov3_adc2544…` directory). Its terms apply to this image.
