# RoMa Matcher v2 Compose

AutoUpdater deploy package for the **RoMa v2 matcher**: the same `roma-matcher` service and the same
HTTP API as the v1 package ([`roma-matcher-compose`](https://github.com/modelingevolution/roma-matcher-compose)),
but matching with RoMa v2 (`romav2==2.0.1`, preset `base`) on the **full frame**. rw2 needs no change:
point `RomaMatcher:BaseAddress` at this package's port.

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
| `docker-compose.yml` | Base service: pinned Harbor image, `runtime: nvidia`, `ROMA_*` env, loopback port `127.0.0.1:7663`, `/health` healthcheck, json-file logging. No `build`, no `depends_on`. |
| `docker-compose.x64.yml` | x86_64 override — `platform: linux/amd64`. AutoUpdater layers it on `uname -m` = `x86_64`. |
| `docker-compose.arm64.yml` | ARM64 override — `platform: linux/arm64`. AutoUpdater layers it on `uname -m` = `aarch64`. |
| `roma-matcher-v2.version` | Bare semver of the pinned release (`0.0.0` = nothing released yet). |
| `update-version.sh` | `set X.Y.Z` pins the image tag across base + overrides and writes the version file; `list` queries Harbor for available `roma-matcher-v2` release tags. |
| `release.sh` | Pins the version, commits + pushes master, then creates + pushes the git tag AutoUpdater detects. |

## Service contract

| Aspect | Value |
|---|---|
| Service / container | `roma-matcher-v2` (compose project `roma-matcher-v2`) |
| Image | `docker.modelingevolution.com/roma-matcher/roma-matcher-v2:<pinned tag>` — one multi-arch manifest (amd64 + arm64), pulled, never built |
| Backend | Image defaults `ROMA_MODEL=v2`, `ROMA_V2_SETTING=base`, `ROMA_CROP_WINDOW_PX=0` (full frame; a per-request `crop_size` is ignored in v2) |
| GPU | `runtime: nvidia`; `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility` |
| Weights | Baked into the image as a torch hub cache (`TORCH_HOME=/models`): `hub/checkpoints/romav2.0.1.pt` + `hub/facebookresearch_dinov3_adc2544…/`. Loads offline. No v1 weights in this image. |
| Ports | `127.0.0.1:7663:7662` — loopback-only; the container listens on 7662, the host port is 7663 so it never collides with the v1 package (7662) |
| Debug dumps | `/var/docker/data/roma-matcher-v2/match-dumps` |
| Healthcheck | `python3 -c urllib` on `/health`; interval 30s, timeout 10s, retries 3, start_period 180s |
| Restart | `unless-stopped` |

Validate the resolved config anywhere (no GPU needed):

```bash
docker compose -f docker-compose.yml -f docker-compose.x64.yml config
```

## One matcher per station (16 GB Jetson)

A 16 GB Jetson cannot run v1 and v2 at the same time: on 2026-11-08 running v2 next to a station's
v1 matcher OOM-killed the v1 matcher. The two packages can be installed side by side without any
port or name clash, but a station **runs one** of them, and rw2's `RomaMatcher:BaseAddress` picks it:

| Station runs | `RomaMatcher:BaseAddress` |
|---|---|
| v1 (`roma-matcher-compose`) | `http://127.0.0.1:7662` |
| v2 (this package) | `http://127.0.0.1:7663` |

## AutoUpdater registration (per station — not automatic)

The v1 package was registered fleet-wide on every NVIDIA device by the AutoUpdater self-update
migration `up-1.0.79.sh` in `autoupdater-compose`, which calls `add-package.sh`. **v2 has no such
migration on purpose**: stations are chosen by the owner, and a station must not run both. On a chosen
station, from the AutoUpdater install directory (the `autoupdater-compose` checkout):

```bash
# 1. Stop the v1 matcher (frees the GPU memory; the v1 package stays registered but idle).
docker compose -p roma-matcher down

# 2. Register v2 as its own Packages[] entry (RepositoryLocation /data/roma-matcher-v2) in
#    /var/docker/configuration/autoupdater/appsettings.Production.json — idempotent:
./add-package.sh roma-matcher-v2 https://github.com/modelingevolution/roma-matcher-v2-compose.git

# 3. Restart AutoUpdater so it reads the new entry, then deploy:
docker restart autoupdater
./autoupdater.sh packages                  # roma-matcher-v2 is listed
./autoupdater.sh update roma-matcher-v2

# 4. Point rw2 at v2: RomaMatcher:BaseAddress = http://127.0.0.1:7663, restart rw2.
```

The resulting entry is the same shape as the v1 one:

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

While the v1 entry stays registered, an AutoUpdater `update-all` would start v1 again. To keep the
station on v2, remove the v1 entry (`RepositoryLocation` `/data/roma-matcher`) from `Packages[]` in the
same file. Going back to v1 is the mirror image: `docker compose -p roma-matcher-v2 down`, register v1,
BaseAddress back to `:7662`.

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
