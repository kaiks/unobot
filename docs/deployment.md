# Neural IRC deployment and rollout

This runbook deploys the IRC-facing `uno` bot with Jedna's deterministic 17.5M
MaskablePPO strategy. It does not authorize a public deployment. Complete each
gate, retain its artifacts, and stop on the stated criteria.

## Architecture and provenance

The deployment is one hardened container with a Ruby parent and a local Python
child. This is intentionally not a sidecar. `ProcessAgent` already owns a
strict stdin/stdout JSON-lines protocol, deadlines, generation cancellation,
process-group TERM/KILL escalation, and reaping. A sidecar would require a
second network protocol and duplicate those lifecycle guarantees without
isolating any state that the accepted strategy interface shares.

The image contains no checkpoint and no copied agent implementation from this
repository. `deploy/build-image` requires the accepted Jedna commit
`17ada2012112abf1df2cd2a31342fcad2f3ed18a`, creates a git archive, and gives
BuildKit only the archived `examples` directory. The Dockerfile allowlists the
six files needed by Simple, Crushing, and neural inference plus Jedna's
license. Training code, repository metadata, dirty working-tree files, and the
checkpoint are outside the image and build context.

That accepted Jedna SHA is not on the current public `origin/main` as of this
handoff. A builder needs a local checkout containing the object, or the commit
must be published/fetched first. This deployment does not solve that external
prerequisite. Do not substitute the remote tip.

Jedna is PolyForm Noncommercial 1.0.0; the image includes
`/opt/jedna-tournaments/JEDNA-LICENSE`. Confirm the intended use is permitted.
This unobot checkout still has no completed license grant, so distribution of
the combined image needs an owner/license decision even when Jedna use is
noncommercial.

## Reproducible build and verification

The deployment pins:

- Fullstaq Ruby 3.4.4 bookworm image digest
  `sha256:fce5b291c13720c64f89e753f1833705bf9c5ac78b060ec87753b0d3ef1f88f9`;
- Bundler 2.3.7 and the committed `Gemfile.lock` (including Cinch `fad9b95`);
- Debian Python 3.11.2, `tini` 0.19.0, and installation package versions;
- Torch 2.8.0+cpu, Stable-Baselines3 2.7.0, sb3-contrib 2.7.0,
  Gymnasium 1.2.0, NumPy 2.3.5, and every resolved Python dependency in
  `deploy/requirements-neural.lock`.

Build and smoke-test the actual checkpoint:

```bash
export JEDNA_ROOT=/absolute/path/to/jedna
export UNO_IMAGE=unobot-neural:17.5m
export UNO_CHECKPOINT="$JEDNA_ROOT/extension-gems/jedna-tournaments/checkpoints/overnight-dagger/checkpoint_17500000_steps.zip"

deploy/build-image
deploy/verify-image
```

The expected model is 3,225,534 bytes with SHA-256
`3399184a589bce389377ca446f1dcb278cdf9123f5a3971031fbee24d5277b4f`.
`deploy/entrypoint` verifies readability and this checksum before Ruby starts,
so a bad mount fails before model load or IRC connection. Override
`UNO_NEURAL_CHECKPOINT_SHA256` only for an explicitly reviewed replacement.
`verify-image` confirms the exact versions, non-root identity, absence of
repository/training/model content, real model load, and three deterministic
warm decisions.

## Runtime configuration and isolation

The safe Compose default is Simple live plus neural shadow, machine messaging,
autojoin off, and fallback off. Required values are `UNO_CHECKPOINT`,
`IRC_SERVER`, `UNO_CHANNELS`, `UNO_HOST_NICKS`, and `UNO_ADMIN_NICKS`.
Comma-separate multiple channels or allowlisted nicks. `IRC_PORT` defaults to
6667 and `IRC_NICK` to `unobot`.

The relevant selectors are:

| Setting | Safe rollout value | Meaning |
| --- | --- | --- |
| `UNO_MESSAGING` | `machine` | `human` or authoritative machine transport |
| `UNO_STRATEGY` | `simple` | live `simple`, `crushing`, or `neural` |
| `UNO_SHADOW_STRATEGY` | `neural` | observer or `none`; never emits an IRC action |
| `UNO_AUTOJOIN` | `false` | public game announcements are ignored |
| `UNO_MACHINE_HUMAN_FALLBACK` | `false` | explicitly allow one-channel machine-to-human fallback |
| `UNO_CHANNELS` | isolated channel | comma-separated channel allowlist |
| `UNO_HOST_NICKS` | exact host aliases | nickname allowlist for game traffic |
| `UNO_ADMIN_NICKS` | operators | legacy configuration; operations use the local socket |

Compose uses UID/GID 10001, read-only root, no Linux capabilities,
`no-new-privileges`, no published ports, 128 PIDs, two CPUs, a 1 GiB memory
limit, read-only checkpoint mount, bounded tmpfs, and a persistent logs volume.
The one-model process previously measured about 378 MiB RSS; the verified
combined container on this host used about 269 MiB while warm and idle. Keep
1 GiB for allocator/model/IRC spikes; treat 768 MiB as an experimental floor,
not the rollout default. Torch thread counts default to one.

Start and inspect:

```bash
docker compose -f deploy/compose.yaml up -d
docker compose -f deploy/compose.yaml exec unobot /unobot/bin/unobotctl health
docker compose -f deploy/compose.yaml exec unobot /unobot/bin/unobotctl ready
docker compose -f deploy/compose.yaml exec unobot /unobot/bin/unobotctl status
```

Do not put IRC passwords, model paths, or tokens in operator requests. This
configuration currently has no TLS/SASL surface: machine notices contain
private hand state, and nickname allowlisting is spoofable on an untrusted IRC
network. Until certificate-verified TLS and account authentication are added,
deployment is restricted to a trusted local/test IRC network. This is a hard
stop for public rollout, not a recommendation that the current config is safe
on the Internet.

## Health, readiness, and local control

The Unix operations socket is disabled unless `UNO_OPERATIONS_SOCKET` is set.
The image uses `/run/unobot/control.sock` in a UID-owned 0700 tmpfs; the socket
is 0600. The server rejects shared, foreign-owned, non-private, or symlinked
parents and accepts one JSON object of at most 4 KiB under a deadline. It is not
published outside the container.

Commands:

- `status`: messaging, live/shadow selection, model health, active game and
  decision IDs, worker/queue/error/drop counters, backoff, and restart state;
- `health`: true only after the real pre-IRC checkpoint inference and while
  that model process and the bridge worker are alive;
- `ready`: health plus IRC runtime start and all configured channels joined;
- `reload`: a fresh reserved checkpoint inference, refused during any live or
  shadow game;
- `select NAME`: validates/selects a live strategy, using the existing
  between-games freeze;
- `fallback`: the existing bounded fail-closed machine-to-human transition;
- `restart`: single-shot graceful process restart, refused while any live or
  shadow game is active.

The surface never returns argv, environment values, checkpoint paths, hands,
stderr contents, or error messages that might contain them. Docker health uses
`health`, not `ready`: IRC outages make the service unready without causing a
model restart storm. Use `bin/unobotctl COMMAND [NAME]` through `docker exec`.

TERM/INT travel through `tini` to a self-pipe signal handler. Cinch stops its
reconnect loop, then the starter ensure path stops operations, bridge, strategy
managers, and the model process group. The bounded smoke exited zero in under
one second and the model PID was gone. Keep Compose's 20-second grace period.

Operational JSON belongs in a restricted artifact directory. Normal Cinch
logs persist in the `unobot-logs` volume; configure host-level rotation and
retention. Shadow JSON can reveal channels, game/decision identifiers, and
actions even though it excludes hands. Do not place it in public logs.

## Mandatory rollout gates

At every gate, retain the sanitized status, version/image ID, decision counts,
shadow agreement/error/drop counts, host/unobot logs, peak memory/PIDs, and
clean shutdown result. Never advance with unexplained errors.

1. **Shadow gate.** Use one isolated channel, `UNO_STRATEGY=simple`,
   `UNO_SHADOW_STRATEGY=neural`, `UNO_AUTOJOIN=false`. Manually join exactly
   one game against one human. Require checkpoint health before IRC, complete
   human/machine canonical parity, one valid shadow result per decision, zero
   shadow drops/errors, no queue growth, and a clean process-group stop.
2. **Isolated live gate.** Keep the same non-public channel and one known human.
   Set `UNO_STRATEGY=neural`, `UNO_SHADOW_STRATEGY=none`, still no autojoin.
   Complete several bounded games with zero invalid/stale/replayed actions and
   stable warm latency/memory.
3. **One human plus one neural.** This is the only supported neural topology.
   Confirm the opponent is human administratively; canonical state can count
   one opponent but cannot classify it. Refuse a second channel/game.
4. **Machine protocol gate.** Use authoritative machine messaging, validate
   registration/action correlation and reconnect/nick-change recovery. Do not
   enable human fallback until this passes.
5. **Fallback drill.** In one test channel only, restart with
   `UNO_MACHINE_HUMAN_FALLBACK=true`. Between games run `unobotctl fallback`.
   Require unregister, fresh human `us`/`ca`, no state merge, no duplicate
   action, and a complete human-protocol game. Human-to-machine requires a
   bounded process restart; do not hot-switch it.
6. **Public opt-in autojoin.** Only after all prior artifacts are reviewed,
   set a dedicated public channel allowlist and `UNO_AUTOJOIN=true`. Enable one
   channel first. The current lack of TLS/account authentication is a blocking
   prerequisite for an untrusted public network.

Stop immediately on any canonical mismatch, invalid/duplicate/stale action,
shadow error/drop, missing lifecycle terminal, model health/backoff loop,
memory over 90% of limit, queue saturation, unbounded retained scopes,
unreaped child, readiness disagreement, unauthorized host/autojoin, or private
state in diagnostics.

## Rollback and recovery

1. Disable `UNO_AUTOJOIN` and stop accepting new games.
2. Let an active game finish. If safety is already compromised, stop the
   container; never replay a pending action.
3. Capture sanitized `status`, image ID, and restricted logs.
4. `docker compose -f deploy/compose.yaml stop` and verify no model PID remains.
5. Roll back to the last reviewed immutable image and restore Simple live with
   no shadow, or the exact legacy human runtime if that is the accepted safe
   service. Do not reuse canonical state across the restart.
6. Keep autojoin off until the incident and artifacts are reviewed.

`reload` is for an idle health inference, not code/config reload. Messaging
human-to-machine, checkpoint changes, and image/config changes always use a
between-games container restart.
