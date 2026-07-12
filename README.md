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
```

The v2 strategies discover a sibling `../jedna` checkout. In another layout,
set `UNO_TOURNAMENT_EXAMPLES` to its tournament `examples` directory, or set
`UNO_SIMPLE_ARGV` / `UNO_CRUSHING_ARGV` to a JSON argv array such as
`["/usr/bin/ruby","/opt/jedna/examples/simple_agent.rb"]`. Operator commands
are trusted configuration but are executed directly, never through a shell.

### Docker Deployment

```bash
# Build the Docker image
docker build . -t unobot

# Run the container
docker run -e TZ=Europe/Berlin --mount source=logs,target=/unobot/logs -p 6667:6667 -it unobot
```

**Note**: On Windows and macOS, update `bot_config.rb` to use `host.docker.internal` instead of `localhost` for the IRC server.

## Configuration

Edit `bot_config.rb` to configure:

- `SERVER`: IRC server address (default: `localhost`)
- `CHANNELS`: IRC channels to join (default: `['#kx']`)
- `NICK`: Bot nickname (default: `unobot`)
- `HOST_NICKS`: Nicknames of the Uno game host bot

See [`docs/unobot-v2.md`](docs/unobot-v2.md) for v2 lifecycle and process
limits.

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
