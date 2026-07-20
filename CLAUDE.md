# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

unobot is an intelligent IRC bot that plays the Uno card game. It uses advanced AI algorithms to make strategic decisions, track opponent cards, and calculate optimal play paths based on probability chains.

### Ruby Version

The project uses Ruby 4.0.6 for both local development and Docker deployment.

## Essential Commands

### Running Tests
```bash
# Run all tests from test directory
cd test && ruby basic.rb
cd test && ruby components_test.rb
cd test && ruby enemy_hand_tracking_test.rb
cd test && ruby uno_ai_test.rb

# Run tests in Docker container
docker run --rm unobot sh -c "cd test && ruby basic.rb"
docker run --rm unobot sh -c "cd test && ruby components_test.rb"
docker run --rm unobot sh -c "cd test && ruby enemy_hand_tracking_test.rb"
docker run --rm unobot sh -c "cd test && ruby uno_ai_test.rb"
```

### Docker Deployment
```bash
# Build the image
docker build . -t unobot

# Run the bot
docker run -e TZ=Europe/Berlin --mount source=logs,target=/unobot/logs -p 6667:6667 -it unobot
```

### Local Development
```bash
# Install dependencies
bundle install

# Create logs directory (required)
mkdir -p logs

# Run the bot locally
ruby uno_bot_starter.rb
```

## Architecture & Key Components

### Core AI System
The bot's intelligence is built around several key components:
- **UnoAI** (`uno_ai.rb`): Main decision-making engine with probability calculations
- **UnoTracker** (`uno_tracker.rb`): Tracks opponent cards and game state
- **UnoProbabilityFinder** (`uno_probability_finder.rb`): Calculates play probabilities
- **UnoPathFinder** (`uno_path_finder.rb`): Finds optimal card sequences

### Game State Management
- **UnoGameState** (`uno_game_state.rb`): Manages game phases (OFF, ON, WAR, WARWD, ONE_CARD)
- **UnoParser** (`uno_parser.rb`): Parses IRC messages and game events
- **UnoPlayer** (`uno_player.rb`): Represents players and their actions

### Configuration
- Main configuration: `bot_config.rb`
- IRC settings: server, channels, nick
- Host bot nicks: ZbojeiJureq variants (the bot that runs the actual game)

### Logging
- Game logs: `/logs/unobot.log`
- Exception logs: `/logs/exceptions.log`
- Custom formatted logger with thread-safe output

## Important Implementation Notes

1. **Thread Safety**: The bot uses a global `$lock` for thread synchronization. Always respect this when modifying shared state.

2. **Game Protocol**: The bot communicates with ZbojeiJureq's uno_plugin via IRC messages. Never modify the message parsing logic without understanding the protocol.

3. **Probability Engine**: The AI uses complex probability chains to determine optimal plays. The `smart_probability` method is the core of this system.

4. **Card Tracking**: The bot maintains a complete model of the card stack and tracks what each opponent might have based on their plays and draws.

5. **Constants**: Several constants are defined in multiple files (GAME_OFF, GAME_ON, etc.). This is intentional for module isolation but causes warnings.
