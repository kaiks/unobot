# unobot v2 messaging runtime

The IRC-facing game and plugin remain named `uno`. `Jedna` names the canonical
engine protocol consumed by strategies.

## Boundaries and opt-in status

The existing Cinch plugin and `UnoAI` runtime remain the default. Requiring
`lib/unobot_v2` and constructing `UnobotV2::Runtime` opts into the v2 path.
`UNO_RUNTIME=legacy|v2` defaults to `legacy` and is the deployment selector;
the application must inject a canonical strategy when constructing the v2
bridge. This stage intentionally does not select a tournament strategy.
`UNO_MESSAGING=human|machine` selects messaging and defaults to `human`;
invalid values fail at startup. Strategy injection is a separate constructor
argument and is never selected by this setting.

There are two independent axes:

- a `MessagingAdapter` turns transport events into an immutable canonical
  `DecisionRequest` and accepts a canonical `Action`;
- a `Strategy` receives only that request and never IRC text.

`Controller` connects the interfaces. `LegacyStrategyAdapter` is the
compatibility boundary for canonical-state callables while the unchanged
legacy Cinch runtime continues to use the current `UnoAI`. A future human or
machine adapter can be swapped without changing a strategy.

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
output retain the IRC-facing `uno` name. The legacy starter remains unchanged
until the selectable strategies required by the next stage exist.

`UnobotV2::CinchBridge` is the concrete v2 attachment. Construct it with the
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

Example application selection:

```ruby
if UnobotV2::Configuration.runtime(ENV) == 'v2'
  bridge = UnobotV2::CinchBridge.new(bot: bot, strategy: injected_strategy)
  bridge.attach!
else
  # Configure the existing UnobotPlugin.
end
```

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
