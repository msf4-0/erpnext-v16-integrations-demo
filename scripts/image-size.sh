#!/usr/bin/env bash
# Measure the compressed (registry) size of one platform of an image, print it,
# and warn/fail against a budget.
#
# Usage: scripts/image-size.sh <ref> [budget-bytes] [platform]
#   ref          e.g. ghcr.io/msf4-0/comp-demo-bench:v16
#   budget-bytes default 3000000000 (3 GB compressed)
#   platform     default linux/amd64
#
# Exit codes:
#   0  measured and within budget
#   1  measured and over budget
#   2  could not measure (registry auth, manifest shape)
set -euo pipefail

ref="${1:?usage: image-size.sh <ref> [budget-bytes] [platform]}"
budget="${2:-3000000000}"
platform="${3:-linux/amd64}"

raw="$(docker buildx imagetools inspect --raw "$ref")" || {
  echo "::warning::could not read the manifest of $ref (not logged in?)"
  exit 2
}

digest="$(printf '%s' "$raw" | python3 -c '
import json, sys
p = sys.argv[1]
m = json.load(sys.stdin)
if "manifests" in m:
    for x in m["manifests"]:
        plat = x.get("platform") or {}
        key = str(plat.get("os")) + "/" + str(plat.get("architecture"))
        if key == p:
            print(x["digest"])
            break
    else:
        sys.exit(3)
' "$platform")" || {
  echo "::warning::$ref has no $platform manifest"
  exit 2
}

if [ -z "$digest" ]; then
  # single-arch image: the raw manifest is already the image manifest
  digest="$ref"
else
  digest="$ref@$digest"
fi

docker buildx imagetools inspect --raw "$digest" | python3 -c '
import json, sys, os
budget = int(sys.argv[1])
m = json.load(sys.stdin)
layers = m.get("layers", [])
total = sum(int(l.get("size", 0)) for l in layers)
manifest_bytes = int(m.get("config", {}).get("size", 0))
total += manifest_bytes
gb = total / 1e9
print(f"compressed layers: {len(layers)}")
print(f"compressed size:   {gb:.2f} GB ({total} bytes)")
print(f"budget:            {budget/1e9:.2f} GB")
if total > budget:
    print("::warning::image is over the documented size budget - see docs/IMAGE-POLICY.md")
    sys.exit(1)
' "$budget"
