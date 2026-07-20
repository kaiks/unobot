# Neural IRC deployment and rollout

This runbook deploys the IRC-facing `uno` bot with Jedna's deterministic
multiplayer v3 MaskablePPO strategy. It does not authorize a public deployment. Complete each
gate, retain its artifacts, and stop on the stated criteria.

## Architecture and provenance

The deployment is one hardened container with a Ruby parent and a local Python
child. This is intentionally not a sidecar. `ProcessAgent` already owns a
strict stdin/stdout JSON-lines protocol, deadlines, generation cancellation,
process-group TERM/KILL escalation, and reaping. A sidecar would require a
second network protocol and duplicate those lifecycle guarantees without
isolating any state that the accepted strategy interface shares.

The image contains no checkpoint and no copied agent implementation from this
repository. `deploy/build-image` archives an explicit unobot commit
(`UNOBOT_REF`, clean `HEAD` by default), rather than sending the mutable
worktree. It requires `JEDNA_REF` and an identical explicitly reviewed
`UNO_ACCEPTED_JEDNA_REF`, then creates a separate named context
containing exactly the six files needed by Simple, Crushing, and neural
inference plus Jedna's license. Training code, repository metadata, dirty
working-tree files, and the checkpoint never enter either BuildKit context.
The image labels record both exact revisions. Any mismatch between the selected
and explicitly accepted Jedna commit is refused. The reviewed commit must
contain the multiplayer-v3 encoder used to train the mounted checkpoint.

Jedna is PolyForm Noncommercial 1.0.0; the image includes
`/opt/jedna-tournaments/JEDNA-LICENSE`. Confirm the intended use is permitted.
This unobot checkout still has no completed license grant, so distribution of
the combined image needs an owner/license decision even when Jedna use is
noncommercial.

## Reproducible build and verification

The deployment pins:

- official Ruby 4.0.6 slim-bookworm linux/amd64 image digest
  `sha256:654c8382a37d73dc8cb7dfe784d711ea82be6aafae2c8fee939149fd80a507c1`;
- Bundler 4.0.16 and the committed `Gemfile.lock` (including Cinch `fad9b95`);
- Debian Python 3.11.2, `tini` 0.19.0, and installation package versions;
- Torch 2.8.0+cpu, Stable-Baselines3 2.7.0, sb3-contrib 2.7.0,
  Gymnasium 1.2.0, NumPy 2.3.5, and every resolved Python dependency in
  `deploy/requirements-neural.lock`, with target-wheel SHA-256 verification;
- security-patched filelock 3.31.1, fonttools 4.63.0, Jinja2 3.1.6,
  Pillow 12.3.0, pip 26.1.2, and setuptools 83.0.0. Direct constraints and
  compatibility bands live in `deploy/requirements-neural.in`.

The build is specifically `linux/amd64`: the base digest, Debian package
versions, and Python wheel hashes do not claim another architecture. Debian
APT metadata and downloaded Ruby gem bodies are still fetched from live
repositories. The base, package versions, Gemfile lock, Cinch git revision,
and resulting image ID are recorded, but the lock does not provide a complete
content hash for those Ruby downloads. Rebuilding therefore
requires trusted package/gem endpoints; retain and deploy the reviewed image
ID or registry RepoDigest rather than treating a later rebuild as identical.

Build and smoke-test the actual checkpoint:

```bash
export JEDNA_ROOT=/absolute/path/to/jedna
export JEDNA_REF=<reviewed-multiplayer-v3-commit>
export UNO_ACCEPTED_JEDNA_REF=$JEDNA_REF
export UNO_IMAGE=unobot-neural:multiplayer-v3
export UNO_CHECKPOINT="$JEDNA_ROOT/extension-gems/jedna-tournaments/models/jedna_multiplayer_v3.zip"

deploy/build-image
deploy/verify-image
deploy/verify-startup-signals

# Compose accepts only an immutable local image ID or registry RepoDigest.
export UNO_IMAGE=$(docker image inspect unobot-neural:multiplayer-v3 --format '{{.Id}}')
```

The expected model is the held-out 9.75M-step checkpoint selected on 2026-07-20:
3,359,191 bytes with SHA-256
`716e687a637632e286e0050b1e013ded46af95033bf5a45901163cc0c141aa15`.
It is the best observed deterministic policy from the weighted Crusher run on
the 2-4-player selection range; it was not statistically distinguishable from
the adjacent 10M checkpoints. On an independent 12,000-game confirmation range
it scored 38.91% macro against Crushing across equally weighted 2-, 3-, and
4-player tables (aggregate Wilson 95% 38.04-39.78%). Jedna's `BOT_RESEARCH.md`
records the complete training, selection, and confidence caveats.
`deploy/entrypoint` verifies readability and this checksum before Ruby starts,
so a bad mount fails before model load or IRC connection. Override
`UNO_NEURAL_CHECKPOINT_SHA256` only for an explicitly reviewed replacement.
`verify-image` confirms the exact versions, non-root identity, absence of
repository/training/model content, real model load, and nine deterministic
warm decisions covering every table size from 2 through 10 players.

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

`UNO_CHECKPOINT` must be an absolute existing file. `deploy/compose-run`
enforces that and refuses mutable image tags; Compose also disables automatic
bind-path creation. Start and inspect:

```bash
deploy/compose-run up -d
deploy/compose-run exec unobot /unobot/bin/unobotctl health
deploy/compose-run exec unobot /unobot/bin/unobotctl ready
deploy/compose-run exec unobot /unobot/bin/unobotctl status
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

The accept loop feeds a bounded client queue and four workers, so one slow
health command or client cannot block status. Input and response I/O default
to separate one-second deadlines (`UNO_OPERATIONS_INPUT_TIMEOUT` and
`UNO_OPERATIONS_OUTPUT_TIMEOUT`); the 4 KiB request and 64 KiB response bounds
are independent. Reload/select execution uses the underlying neural cold/warm
and process deadlines. `UNO_OPERATIONS_SHUTDOWN_TIMEOUT` defaults to 30 seconds
and must remain above the configured cold timeout; shutdown closes client I/O
and joins every worker without killing an inference thread.

The surface never returns argv, environment values, checkpoint paths, hands,
stderr contents, or error messages that might contain them. Docker health uses
`health`, not `ready`: IRC outages make the service unready without causing a
model restart storm. Use `bin/unobotctl COMMAND [NAME]` through `docker exec`.

TERM/INT traps and the self-pipe are installed before model health begins. A
startup signal records termination without raising into Torch; bounded health
finishes, IRC startup is skipped/stopped, and ensure shuts down operations,
bridge, managers, and the model group. Normal TERM exits zero. The operator
restart command holds manager admission closed and exits 75 after cleanup;
Compose's bounded `on-failure:3` policy restarts it. Configuration exit 78 is
also retried at most three times instead of looping forever. Keep the 20-second
grace period at or above the neural cold timeout.

Operational JSON belongs in a restricted artifact directory. Normal file logs
persist in `unobot-logs`; `UNO_LOG_MAX_BYTES` defaults to 10 MiB and
`UNO_LOG_BACKUPS` to three for both files, bounding each log family to four
files. Docker JSON output is separately capped at three 10 MiB files. Shadow
JSON can reveal channels, game/decision identifiers, and actions even though
it excludes hands. Do not place it in public logs.

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
3. **Multiplayer topology.** Start with one human plus the neural player, then
   exercise 3-10 total players. At every decision require the canonical state
   to contain every opponent ID and exact public hand size in current turn
   order. The single active neural game limit remains in force across channels.
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
4. `deploy/compose-run stop` and verify no model PID remains.
5. Roll back to the last reviewed immutable image and restore Simple live with
   no shadow, or the exact legacy human runtime if that is the accepted safe
   service. Do not reuse canonical state across the restart.
6. Keep autojoin off until the incident and artifacts are reviewed.

`reload` is for an idle health inference, not code/config reload. Messaging
human-to-machine, checkpoint changes, and image/config changes always use a
between-games container restart.
