# unobot v2 human messaging foundation

The IRC-facing game and plugin remain named `uno`. `Jedna` names the canonical
engine protocol consumed by strategies.

## Boundaries and opt-in status

The existing Cinch plugin and `UnoAI` runtime remain the default. Requiring
`lib/unobot_v2` opts into the new foundation; Stage 4 will add the runtime
configuration and machine transport.

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
and triggers resynchronization. Consumer errors are isolated and delivered to
an error callback. Stop/restart joins the old worker before replacing it.

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
the private `You draw ...` notice supplies the picked card.

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
