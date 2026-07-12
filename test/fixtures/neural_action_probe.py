"""Emit every action enabled by Jedna's dependency-free neural action mask."""

import json
import sys

sys.path.insert(0, sys.argv[1])

from rl_agent.encoding import ActionSpace, encode_action_mask


space = ActionSpace()
states = json.load(sys.stdin)
responses = []
for state in states:
    mask = encode_action_mask(space, state)
    responses.append(
        [space.to_protocol(index, state) for index, enabled in enumerate(mask) if enabled]
    )
json.dump(responses, sys.stdout, separators=(",", ":"))
