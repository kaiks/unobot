"""Small stdlib-only stand-in that exercises the production module argv."""

import argparse
import json
import sys


parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--stochastic", action="store_true")
args = parser.parse_args()

with open(args.model, "rb") as checkpoint:
    checkpoint.read(1)

for line in sys.stdin:
    message = json.loads(line)
    if message.get("type") != "request_action":
        continue
    action = "pass" if args.stochastic else "draw"
    print(json.dumps({"action": action}, separators=(",", ":")), flush=True)
