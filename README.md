# unobot

An intelligent IRC bot that plays the Uno card game with advanced AI strategies.

## Overview

unobot is a sophisticated Uno game player that uses probability calculations and card tracking to make optimal decisions. It connects to an IRC server where [ZbojeiJureq](https://github.com/kaiks/ZbojeiJureq) hosts Uno games and plays automatically.

### Key Features

- **Algorithmic play**: Uses probability chains to calculate optimal card play sequences
- **Card Tracking**: Tracks opponent cards based on plays and draws
- **Strategic Decision Making**: Considers game state (war mode, uno calls, etc.)
- **Multi-threaded**: Handles IRC communication and game logic concurrently

## Requirements

- Ruby 3.0+ (development)
- Ruby 3.4.4 (Docker deployment)
- Bundler

## Installation

### Local Development

```bash
# Clone the repository
git clone <repository-url>
cd unobot

# Install dependencies
bundle install

# Create logs directory
mkdir -p logs

# Run the bot
ruby uno_bot_starter.rb
```

The unchanged legacy bot remains the default. The v2 runtime selects Jedna
messaging and strategy independently:

```bash
# Existing UnoAI and human-text plugin
UNO_RUNTIME=legacy bundle exec ruby uno_bot_starter.rb

# Maintained Jedna Simple strategy over human text
UNO_RUNTIME=v2 UNO_MESSAGING=human UNO_STRATEGY=simple \
  bundle exec ruby uno_bot_starter.rb

# Maintained Jedna Crushing strategy over the machine protocol
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=crushing \
  bundle exec ruby uno_bot_starter.rb

# Persistent deterministic 17.5M neural policy (one two-player game globally)
UNO_RUNTIME=v2 UNO_MESSAGING=machine UNO_STRATEGY=neural \
  UNO_NEURAL_CHECKPOINT=/models/checkpoint_17500000_steps.zip \
  bundle exec ruby uno_bot_starter.rb
```

The v2 strategies discover a sibling `../jedna` checkout. In another layout,
set `UNO_TOURNAMENT_EXAMPLES` to its tournament `examples` directory, or set
`UNO_SIMPLE_ARGV` / `UNO_CRUSHING_ARGV` to a JSON argv array such as
`["/usr/bin/ruby","/opt/jedna/examples/simple_agent.rb"]`. Operator commands
are trusted configuration but are executed directly, never through a shell.

The neural strategy executes `python3 -m rl_agent.sb3_opponent` from the
validated tournament examples directory and passes the checkpoint as an argv
value. It is deterministic by default; `UNO_NEURAL_STOCHASTIC=true` is an
explicit opt-in. See the v2 documentation for health deadlines, process reuse,
and the initial two-player/single-process limit.

### Docker Deployment

```bash
# Build the pinned combined Ruby/Python inference image from an accepted Jedna checkout
JEDNA_ROOT=../jedna UNO_IMAGE=unobot-neural:17.5m deploy/build-image

# Configure the external read-only model and IRC allowlists, then start safely in shadow mode
export UNO_CHECKPOINT=../jedna/extension-gems/jedna-tournaments/checkpoints/overnight-dagger/checkpoint_17500000_steps.zip
export IRC_SERVER=irc.example.test UNO_CHANNELS='#uno-test'
export UNO_HOST_NICKS=ZbojeiJureq UNO_ADMIN_NICKS=operator
docker compose -f deploy/compose.yaml up -d
```

This bot is an outbound IRC client; no container port is published. The model
is never built into the image. See [`docs/deployment.md`](docs/deployment.md)
for provenance, health checks, operator commands, resource limits, and the
mandatory rollout/rollback gates.

## Configuration

Edit `bot_config.rb` to configure:

- `SERVER`: IRC server address (default: `localhost`)
- `PORT`: IRC server port (default: `6667`)
- `CHANNELS`: IRC channels to join (default: `['#kx']`)
- `NICK`: Bot nickname (default: `unobot`)
- `HOST_NICKS`: Nicknames of the Uno game host bot

See [`docs/unobot-v2.md`](docs/unobot-v2.md) for v2 lifecycle and process
limits. Deployment values can be supplied with `IRC_SERVER`, `IRC_PORT`,
`IRC_NICK`, `UNO_CHANNELS`, `UNO_HOST_NICKS`, and `UNO_ADMIN_NICKS`.

## Testing

Run the test suite to verify the AI logic:

```bash
# Run individual tests
cd test
ruby basic.rb              # Core AI strategy tests
ruby components_test.rb    # Component unit tests
ruby enemy_hand_tracking_test.rb  # Card tracking tests
ruby uno_ai_test.rb       # AI decision tests

# Run tests in Docker
docker run --rm unobot sh -c "cd test && ruby basic.rb"

# Run mutation tests during development
bundle exec mutant run
```

## Architecture

- **UnoAI** (`lib/uno_ai.rb`): Main AI engine with probability calculations
- **UnoTracker** (`lib/uno_tracker.rb`): Tracks cards and game state
- **UnoParser** (`lib/uno_parser.rb`): Parses IRC messages from the game host
- **UnoBotPlugin** (`lib/uno_bot_plugin.rb`): Cinch plugin for IRC integration

## How It Works

1. The bot connects to an IRC server and joins configured channels
2. It listens for game messages from ZbojeiJureq (the Uno game host)
3. When it's the bot's turn, it:
   - Analyzes the current game state
   - Calculates probabilities for different play sequences
   - Chooses the optimal card to play
   - Sends the play command back to the game host

## Contributing

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture notes.

## License

[License information here]
