# ACE-Step gate: run your own remote generation server

Majiks Music Studio can generate on a **remote GPU** (Settings → Generation Settings → **Remote Only** or **Both**).
The gate is the server side of that mode. It is a small, key-protected front door to
[ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5) on a Linux box with an NVIDIA card. It lets you, your band,
or your Claude generate from anywhere on your network, and it keeps the GPU free when nobody is using it.

- **Per-person keys.** Each person gets their own key, with an expiry, and you can revoke any one of them on its
  own. Only SHA-256 hashes are stored on the server.
- **Loads on demand, unloads when idle.** The first job starts ACE-Step; after 10 idle minutes (configurable) the
  gate stops it and the VRAM is freed. On an RTX 3090: 16–18 s cold start, then about 4 s for a 30 s track.
- **Small surface.** The gate exposes only the endpoints the app uses. ACE-Step's own training, dataset and LoRA
  routes stay on localhost, where nothing can reach them.
- **Shares the GPU politely.** If something else is already serving ACE-Step on the backend port, the gate uses it
  and never stops it.

## Requirements

- Linux with an NVIDIA GPU (24 GB is comfortable for the turbo model with the LM off), systemd, and Python 3.11+.
- A working ACE-Step 1.5 checkout with its venv (follow ACE-Step's own install). Add `fastapi uvicorn httpx` to that
  venv if they are not already there.

## Install

```bash
sudo useradd --system --create-home --home-dir /opt/acestep-gate acestep   # or use an existing user
sudo cp gate.py gate_keys.py /opt/acestep-gate/
sudo cp gate.env.example /etc/acestep-gate.env && sudoedit /etc/acestep-gate.env   # paths, GPU, port
sudo cp acestep-gate.service /etc/systemd/system/
sudo systemctl edit acestep-gate        # only if you run it as another user or from another directory
sudo systemctl daemon-reload && sudo systemctl enable --now acestep-gate
curl http://localhost:8010/health        # {"status":"ok"}
```

Make sure the user the gate runs as can read the ACE-Step checkout and use the GPU.

**Network:** the gate speaks plain HTTP. Keep it on a private network (LAN, Tailscale, Headscale or WireGuard). To
reach it over the internet, put a TLS reverse proxy in front.

## Keys

```bash
cd /opt/acestep-gate
sudo -u acestep python3 gate_keys.py add alice --days 365   # prints the key ONCE on stdout
sudo -u acestep python3 gate_keys.py list
sudo -u acestep python3 gate_keys.py revoke alice
```

The key is the only thing written to stdout, so you can pipe it straight into a password manager instead of
showing it on screen. Changes take effect on the next request; no restart is needed. Each key may have at most 4
unfinished jobs (`GATE_MAX_ACTIVE_PER_KEY`).

## Connect the app

Majiks Music Studio → Settings → Generation Settings:

- **Server URL:** `http://<gate host>:8010`
- **Generation Mode:** Remote Only (or Both to use local and remote together)
- **API Key:** the key from `gate_keys.py add`

Press **Test**. To let a Claude drive it, use Settings → **Copy MCP Config** and add that to your Claude. Its
generate tools then run on the remote GPU.

## API

Send `Authorization: Bearer <key>` on every route except `/health`.

| Route | Does |
|---|---|
| `GET /health` | Liveness check, no auth |
| `GET /api/v1/studio/health` | Checks the key and reports whether the generator is warm |
| `POST /api/v1/studio/generate` | Takes `{"params": {"tags", "lyrics", "instrumental", "duration", "tempo", "key", "seed", "vocal_language", "num_inference_steps", "genre", "mood"}}` and returns `{"id"}` immediately |
| `GET /api/v1/studio/jobs/{id}` | Returns `warming` / `queued` / `running` / `completed` (with `result.variants[].metadata`) / `failed` |
| `GET /api/v1/studio/jobs/{id}/audio?variant=0` | Returns the WAV (48 kHz) |
| `POST /api/v1/studio/jobs/{id}/save` | No-op (the gate keeps no library) |

Any other path returns 404. Jobs are visible only to the key that submitted them. Server-side clamps: duration
10–480 s, 1–20 steps, one variant per job.

## Smoke test

Run `smoke.py` on the gate host as the gate's user. It adds a one-day key, renders a 30 s instrumental through the
gate, checks the WAV, and revokes the key whether or not the render succeeds.

## Tips

- Keep lyric sheets to about 15 lines. Dense sheets make ACE-Step drop a whole section to fit the duration.
- The first ~20 s of a short render is often an instrumental intro, so the opening line may not be sung.
