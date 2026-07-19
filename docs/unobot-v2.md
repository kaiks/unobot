# unobot v2 messaging runtime

The IRC-facing game and plugin remain named `uno`. `Jedna` names the canonical
engine protocol consumed by strategies.

## Boundaries and opt-in status

The existing Cinch plugin and `UnoAI` runtime remain the default.
`UNO_RUNTIME=legacy|v2` defaults to `legacy`. The actual starter installs only
`UnobotPlugin` in legacy mode, or only `StrategyManager` plus `CinchBridge` in
v2 mode; the callback sets cannot be installed together.

V2 has two independent selectors. `UNO_MESSAGING=human|machine` defaults to
`human`, while `UNO_STRATEGY=legacy|simple|crushing|neural` chooses a canonical
strategy. `simple` and `crushing` execute the maintained Jedna tournament
programs rather than copies in this repository. `v2 + legacy` is rejected:
the historical `UnoAI` depends on mutable tracker history, previous/last-card
players, turn counters, global bot identity, and a transport-writing proxy that
cannot be reconstructed faithfully from one canonical snapshot.
`UNO_RUNTIME=legacy` is the faithful choice and accepts only its real
`human + legacy` combination. No selector is silently ignored. Invalid
combinations and missing executables fail before IRC connects.

There are two independent axes:

- a `MessagingAdapter` turns transport events into an immutable canonical
  `DecisionRequest` and accepts a canonical `Action`;
- a `Strategy` receives only that request and never IRC text.

`Controller` connects the interfaces. `StrategyManager` freezes the selected
strategy while any game is active and permits changes only after every active
game ends. Machine sessions use channel plus authoritative `game_id`; human
sessions use channel plus a conservative game generation that changes on a
new game, not an ordinary status resynchronization. Multi-channel machine
games own independent strategy/process instances.

`SessionManager` owns one adapter per normalized channel and feeds every event
through one bounded `OrderedConsumer`. Cinch callbacks should only construct a
`Human::Event` and call `enqueue`. The reducer and strategy therefore execute
in order and off the callback thread. Queue overflow is reported as refusal
and triggers resynchronization on the consumer thread. Overflow advances the
affected channel's lifecycle epoch immediately; in-flight decisions recheck
that token before callback/action delivery, stale queued envelopes are dropped,
and only a fresh status/private/hand boundary can restore safety. Consumer
errors are isolated and delivered to an error callback. Stop/restart joins the
old worker before replacing it.

## Canonical request

`Canonical::DecisionRequest` is Jedna `request_action` protocol version 1:
identity, hand, colored top card, game mode, stacked penalty, picked state,
ordered opponent counts, available actions, and playable cards. Metadata adds
channel, transport, generation/turn correlation, decision ID, confidence, and
per-fact provenance without changing `protocol_h`. Values are recursively
frozen, validated, comparable, and deterministically JSON-serializable.

Vendored engine-generated contract fixtures live in
`test/fixtures/jedna_protocol_v1` with accepted source commit and checksums.

## Human confidence and recovery

The reducer accepts game messages only from configured host nicks. Private
hand, draw, status-private, and picked-card data are accepted only when the
recipient is the client. Sessions are channel-scoped.

Facts are tagged:

- `exact`: directly stated by a private hand/status or public top/count line;
- `derived`: deterministically updated from a complete prior state and Jedna
  turn rules;
- `uncertain`: malformed, contradictory, missing, overflowing, disconnected,
  or otherwise incoherent input.

A continuously observed transcript becomes safe after player counts, the
client's private hand, and a turn/top line are known. Plays, double markers,
draws, normal/war passes, reverse, skip, selected wilds, and order/count changes
are then reduced in order. After the client draws, no decision is emitted until
the correlated private `You draw ...` notice supplies the picked card. Public
single draws, private picked-card notices, and private multi-card war penalties
have separate expected transitions; duplicates, missing counterparts, count
mismatches, and out-of-turn draws force resynchronization rather than changing
the hand twice.

Any detected gap or contradiction makes the state unsafe. The adapter sends
`us` and `ca`, refuses actions, and becomes safe only after a coherent
`UNO_STATUS_V1` plus (for the current client) `UNO_STATUS_PRIVATE_V1` and a full
private hand agree. Reconnect sends the same pair. A disconnect invalidates the
generation but waits for reconnect before sending. Repeated status/turn lines
produce the same decision ID, so strategy and action submission are deduplicated.

Reasonable fallback assumptions are deliberately narrow: host nick
allowlisting is correct; IRC preserves order within one connection; `ca`
contains the complete requesting player's hand; the frozen status line is an
atomic authoritative snapshot; and all continuously observed public game
events use the accepted host strings. Hidden opponent cards and deck order are
never guessed.

IRC notices do not carry their originating channel. Ingress must therefore
attach a channel to each private `Human::Event` only when correlation is
unambiguous (the current legacy deployment configures one game channel). If
two sessions could both own a hand/status notice, ingress must not deliver it
to either reducer; both remain unsafe until they are resynchronized one at a
time. The adapter deliberately has no "most recent channel" guess.

`Runtime.from_env` installs the selected adapter and ordered ingress. IRC
callbacks should only translate incoming data into `Human::Event` (channel
messages/private human replies) or `Machine::Event` (private NOTICE and
lifecycle callbacks) and call `enqueue`. Machine registration and ACTION
output retain the IRC-facing `uno` name. The repository starter selects and
attaches the complete runtime before `$bot.start`.

`UnobotV2::CinchBridge` is the concrete v2 attachment. Load it with
`require 'unobot_v2/cinch_bridge'`, construct it with the
connected `Cinch::Bot` and an injected strategy, then call `attach!` before the
bot starts. It installs minimal synchronous dispatch-boundary handlers which
only snapshot immutable callback data and nonblockingly enqueue it. A bridge
worker maps those snapshots and controls the runtime, preserving IRC dispatch
order without running protocol parsing, strategy code, or transport output on
the Cinch callback thread. Runtime startup waits until the bot has joined every
configured channel; periodic machine expiry ticks are driven automatically.

The bridge sends channel registration and human commands with
`Channel#send`. Correlated machine ACTION goes to the host alias that actually
sent REGISTERED using private `User#send`; it never uses NOTICE for client
actions. Private NOTICE recipient correlation uses the first IRC parameter,
not Cinch's private-message `target`. Human mode requires exactly one channel
because private status and hand notices do not encode a channel. Multi-channel
machine mode is supported, but machine-to-human fallback is rejected there.

Operator examples:

```bash
UNO_RUNTIME=legacy bundle exec ruby uno_bot_starter.rb
UNO_RUNTIME=v2 UNO_MESSAGING=human UNO_STRATEGY=simple bundle exec ruby uno_bot_starter.rb
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=simple bundle exec ruby uno_bot_starter.rb
UNO_RUNTIME=v2 UNO_MESSAGING=human UNO_STRATEGY=crushing bundle exec ruby uno_bot_starter.rb
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=crushing bundle exec ruby uno_bot_starter.rb
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=neural UNO_NEURAL_CHECKPOINT=/models/jedna_multiplayer_v3.zip bundle exec ruby uno_bot_starter.rb
```

V2 does not join newly announced games unless the operator explicitly sets
`UNO_AUTOJOIN=true`. When enabled, only a configured host's game-created line
in a configured channel can trigger `jo`. Machine mode then registers again
after the host confirms that this nick joined, replacing an earlier `no_game`
or `not_player` registration attempt with authoritative game state.

By default, agents are discovered in a sibling `jedna` checkout under
`extension-gems/jedna-tournaments/examples`. Set
`UNO_TOURNAMENT_EXAMPLES=/absolute/path/to/examples` elsewhere. An individual
agent may instead use `UNO_SIMPLE_ARGV` or `UNO_CRUSHING_ARGV`, whose value is a
JSON array of non-empty argv strings. No shell string is accepted or
interpolated. Useful bounds are `UNO_AGENT_STARTUP_TIMEOUT`,
`UNO_AGENT_REQUEST_TIMEOUT`, `UNO_AGENT_SHUTDOWN_TIMEOUT`,
`UNO_AGENT_MAX_STDOUT_LINE`, and `UNO_AGENT_STDERR_TAIL_BYTES`.

The generic process strategy accepts exactly the Jedna v1 `request_action`
object on stdin and exactly one JSON object line on stdout. Stdout is
protocol-only; stderr is drained concurrently into bounded private tail
storage, while public diagnostics expose only byte counts and structured
status. Startup and shutdown are bounded. One request deadline covers both a
nonblocking stdin write and the response read, so a child that stops reading
cannot wedge cancellation or shutdown. Malformed, noisy, oversized,
timed-out, late-after-cancellation, or invalid actions fail closed.
Cancellation advances a generation token, terminates the process group with
TERM/KILL escalation, and reaps it. `per_game` is the stock policy; the
process layer also supports the `persistent` lifecycle used by the neural
strategy.

## Neural strategy

Before allowing neural actions onto IRC, run another strategy live and set
`UNO_SHADOW_STRATEGY=neural`. The neural manager is health-checked before IRC
attachment and then receives every immutable canonical decision on a separate
bounded worker. Its validated action and whether it agrees with the live action
are emitted as one `[unobot shadow]` JSON object on stderr. Shadow output is
never submitted to either messaging adapter; a slow, crashed, or saturated
shadow reports an error/drop and cannot delay or replace the live action.
Redirect stderr to retain the rollout artifact. `none` (the default), `simple`,
and `crushing` are also accepted for differential checks.

```bash
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=simple \
  UNO_SHADOW_STRATEGY=neural \
  UNO_NEURAL_CHECKPOINT=/models/jedna_multiplayer_v3.zip \
  bundle exec ruby uno_bot_starter.rb 2>shadow.jsonl
```

`UNO_STRATEGY=neural` runs the maintained persistent module
`python3 -m rl_agent.sb3_opponent --model CHECKPOINT` with no shell
interpolation. `UNO_TOURNAMENT_EXAMPLES` is a validated working directory and
must contain `rl_agent/sb3_opponent.py`; `UNO_NEURAL_CHECKPOINT` must be a
readable external file. In the sibling Jedna layout it defaults to
`models/jedna_multiplayer_v3.zip`. Override the
executable with the single argv value `UNO_NEURAL_PYTHON` when needed. The
model is never copied into or loaded from this repository.

Prediction is deterministic unless `UNO_NEURAL_STOCHASTIC=true` is explicitly
set. `UNO_NEURAL_COLD_TIMEOUT` defaults to 15 seconds and covers the first
request after process spawn, including model load; `UNO_NEURAL_WARM_TIMEOUT`
defaults to 1 second. Spawning itself is bounded by
`UNO_NEURAL_SPAWN_TIMEOUT` (5 seconds). The upstream module emits no ready
marker, so after validating executable/module/checkpoint paths the selected
neural manager sends one reserved, valid canonical decision under
the cold deadline. Its action is validated and a game-end/reset is delivered
before the IRC bridge is attached. The feed-forward module has no per-game
memory and ignores that lifecycle frame, leaving the verified process warm and
idle for the first live game. Load or inference failure aborts configuration;
diagnostics report `unverified`, `loading`, `ready`, or `failed` without
exposing argv, paths, or stderr contents.

The healthy process stays warm across `game_end`/new-game resets. Timeouts,
crashes, invalid output, and failed model loads terminate and reap its process
group, then impose exponential restart backoff. Configure the 1-second initial
and 30-second maximum bounds with `UNO_NEURAL_BACKOFF_INITIAL` and
`UNO_NEURAL_BACKOFF_MAX`. Cancellation and shutdown invalidate the current
generation immediately; shutdown escalates TERM/KILL and reaps the group.
Every successful child spawn advances a process generation. If a warm process
dies while idle, its replacement is marked cold even though it is already alive
by the time `start_game` returns, so model reload can never inherit the shorter
warm deadline.

The multiplayer v3 policy accepts one through nine ordered `other_players`
entries, representing 2-10 total players. The human reducer and authoritative
machine protocol both preserve each public player ID and hand size in current
turn order. The manager still permits only one active neural game across all
channels, so it never allocates a second roughly 377 MiB model process.
Topologies outside 2-10 players are rejected before process/session use and
cannot consume that global slot.

Human messaging filters the canonical request through `ActionEncoder` before
strategy inference. Any card/action variant the IRC grammar cannot express is
removed conservatively; an empty mask refuses inference and requests a fresh
`us`/`ca` snapshot. Machine messaging bypasses this transport-specific mask
and retains the full canonical action space. The current human grammar covers
draw, pass, wild colors, ordinary doubles, and double WD4 (`pl wd4rwd4r`).

The dependency-free action-space contract can be checked with:

```bash
cd /path/to/jedna/extension-gems/jedna-tournaments/examples
python3 -m unittest rl_agent.test_encoding
cd /path/to/unobot
ruby -Itest test/unobot_v2_neural_contract_test.rb
```

The external model smoke is opt-in:

```bash
UNO_RUN_REAL_NEURAL_TESTS=1 ruby -Itest test/unobot_v2_neural_real_test.rb
```

For a complete external game smoke, use Jedna's maintained
runner (its agent-command interface is a test harness, not unobot's production
spawn path):

```bash
cd /path/to/jedna/extension-gems/jedna-tournaments/examples
mise exec ruby@3.4.4 -- bundle exec ruby ./run_single_game.rb \
  "python3 -m rl_agent.sb3_opponent --model ../models/jedna_multiplayer_v3.zip" \
  "./simple_agent.rb"
```

Success means the runner prints `Game Over!` and a final winner before its
30-second game deadline. This remains opt-in because Torch/SB3, the external
checkpoint, and the Jedna bundle are intentionally not unobot dependencies.

Jedna's response line has no request ID or end-of-response marker. A buffered
or immediate second line therefore fails the current request, and unsolicited
output already present before the next request fails and kills the process.
An arbitrarily delayed second line cannot retroactively revoke a valid first
line that was already accepted; detecting that would require delaying every
action for the whole turn deadline. The maintained agents honor the one-line
contract, and any delayed extra line is rejected before a later request uses
that process.

## Machine transport and recovery

Machine mode sends `.uno machine register` in every configured game channel.
It accepts private host NOTICE frames only for the configured nick. REGISTERED
is routed by its encoded channel while pending; every later frame is routed by
the authoritative game ID. STATE and EVENT use strict, bounded v1 reassembly:
400-byte wire lines, 128-character chunks, at most 999 chunks, 64 interleaved
frames, 512 KiB encoded/decompressed limits, and a 30-second incomplete-frame
deadline. ACTION is uncompressed Base64url JSON limited to 220 characters and
uses the host's 12-byte SHA-256 correlation.

Malformed traffic is reported structurally and isolated. Corrupt, missing,
evicted, or overflowing active-session data invalidates the decision and
re-registers for an authoritative `registration_sync`; no action is replayed.
Retryable host errors reopen only their exact active decision for explicit
resubmission and never invoke the strategy twice. Nonretryable errors,
disconnects, nick changes, and terminal events clear state. Reconnect and nick
recovery register afresh. Queue overflow advances the ingress lifecycle epoch
before recovery, so an in-flight strategy result cannot escape afterward.
Call `runtime.tick` from the IRC integration's periodic timer; expiry checks
are enqueued on the same ordered path and recover incomplete frames after the
30-second deadline even when no further NOTICE arrives. The same tick treats
a 30-second missing ACK as uncertain execution: it invalidates and
re-registers but never replays the action.

Start, registration, graceful unregister/stop, fallback, and explicit resync
are ordered controls on the ingress worker. Operator controls invalidate the
decision epoch before waiting, use bounded queue-admission and completion
deadlines, and return structured `control_timeout` outcomes. A transition
requested from the ingress worker returns `restart_required` rather than
self-joining. Graceful stop best-effort unregisters while still connected.
PART, QUIT, and KICK affect a session only when their affected nick is this
client; departure invalidates without trying to register while absent, and a
later own JOIN/reconnect performs fresh registration.

Nonretryable stale/protocol/transport failures re-register for authoritative
state. Terminal authorization/game errors (`no_game`, `not_allowlisted`,
`not_player`, `game_changed`, `registration_taken`, `not_registered`,
`unknown_game`, `game_ended`, and `unauthorized`) remain stopped in their named
lifecycle state until the operator or IRC lifecycle explicitly starts a new
registration; they do not create a registration loop.

After a retryable executor error, the stock deterministic strategies cancel
their local game process and request authoritative machine re-registration.
They never replay the IRC action or call the strategy twice. The strategy
boundary permits a future explicitly retry-capable strategy to supply a newly
validated replacement action, but silent replay remains forbidden.

Private NOTICE has no channel, so the machine ingress never uses a most-recent
channel guess. Registration errors without a game ID are routed only when one
registration is pending. Multiple pending registrations make such a frame
unroutable.

## Controlled fallback

Machine-to-human fallback is disabled by default. Set
`UNO_MACHINE_HUMAN_FALLBACK=true` and explicitly call
`runtime.transition_to('human')` to use it. The runtime first delivers
`.uno machine unregister` for every session and invalidates machine decisions,
then discards all machine state, creates fresh unsafe human reducers, and sends
`us` plus `ca`. Strategy execution remains blocked until a coherent human
status/private/hand boundary arrives. Failure to deliver unregister leaves the
runtime in fail-closed machine mode.

Human-to-machine live transition returns `restart_required`. Restart the v2
runtime explicitly so registration begins outside an active human decision;
partial human and machine state are never merged.

## Human action syntax

The encoder validates the action against the active safe decision:

- draw: `pe`
- pass/war penalty: `pa`
- play: `pl <card>`
- colored wild: `pl wr`, `pl wd4g`, and so on
- doubles repeat the complete code, including `pl wd4rwd4r`

Wild color is required and must be red, green, blue, or yellow. Post-draw play
is restricted to the exact picked card. Doubles require two matching cards and
are unavailable after drawing. An unavailable, stale, duplicate, unsafe, or
unexpressible action returns a structured refusal; the encoder never substitutes
another action or narrows Jedna's legal actions.
