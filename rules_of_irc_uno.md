# Rules of IRC Uno

## Objective
Be the first player to play all cards from your hand.

## Basic Playability Rules

### Normal State
A card can be played if it matches the top card by:
1. **Same Color** - e.g., Red 5 → Red 9
2. **Same Number/Figure** - e.g., Red 5 → Blue 5
3. **Wild Cards** - Can always be played (Wild, Wild Draw 4)

### War States
Special states that restrict what can be played:

#### Draw Two War (+2 War)
- **Triggered by**: Someone plays a +2 card
- **Playable cards**: Only +2 or Wild Draw 4
- **Effect**: Draw penalty accumulates (2, 4, 6, 8...)
- **Resolution**: When a player can't continue, they draw all accumulated cards

#### Wild Draw Four War (WD4 War)
- **Triggered by**: Someone plays a Wild Draw 4
- **Playable cards**: Only Wild Draw 4
- **Effect**: Draw penalty accumulates (4, 8, 12...)
- **Resolution**: When a player can't continue, they draw all accumulated cards

## Card Types and Effects

### Number Cards (0-9)
- No special effect
- Playable based on color or number match

### Action Cards
- **Skip (S)**: Next player loses their turn
- **Reverse (R)**: Reverses play direction (in 2-player, acts like Skip)
- **Draw Two (+2)**: Next player must respond with +2/WD4 or draw 2 cards

### Wild Cards
- **Wild (W)**: Choose any color for next play
- **Wild Draw Four (WD4)**: Choose color, next player must respond with WD4 or draw 4

## Special Play Mechanics

### Double Play
- Two identical cards (same color AND number) can be played simultaneously
- Notation: "r5r5" for two Red 5s
- Only works for number cards and Skip (not +2, Reverse, or Wilds)

### Passing
- If you cannot play, you must draw one card
- In war states, if you cannot respond, you draw the accumulated penalty

## Turn Order
- Clockwise by default
- Reverse cards change direction
- Skip cards bypass next player
- In 2-player: Reverse acts as Skip

## Winning Conditions
1. First player to play all their cards wins
2. Must call "Uno" when down to one card (implementation dependent)
3. Game ends immediately when a player plays their last card

## Scoring (if used)
Points are typically awarded based on cards left in opponents' hands:
- Number cards: Face value (0-9)
- Action cards: 20 points each
- Wild cards: 50 points each

## IRC-Specific Rules
1. All actions via text commands (pl = play, pe = pick/draw, pa = pass)
2. No time limits on turns
3. Perfect information NOT available via IRC logs (you don't know the order of the stack, and what cards the opponents have)
4. Bot enforcement of rules
