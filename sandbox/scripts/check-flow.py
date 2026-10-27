#!/usr/bin/env python
"""Read-only summary of a Node-RED flow export.

Used by setup.ps1 to refuse deploying a flow that lost its nodes during the
rebuild, and by humans to eyeball an export.

    python sandbox/scripts/check-flow.py sandbox/node-red/flows.json
"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "sandbox/node-red/flows.json"

with open(path, encoding="utf-8") as fh:
    flow = json.load(fh)

http_in = [n for n in flow if n.get("type") == "http in"]
print("nodes      :", len(flow))
print("tabs       :", ", ".join(n.get("label", "?") for n in flow if n.get("type") == "tab"))
print("http in    :", len(http_in))
for node in http_in:
    print("  endpoint :", node.get("url"), "method:", node.get("method", "get"))
print("http resp  :", sum(1 for n in flow if n.get("type") == "http response"))
