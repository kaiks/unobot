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
