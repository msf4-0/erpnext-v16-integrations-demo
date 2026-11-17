#!/usr/bin/env bash
# Prove the HOST source-of-truth tree would install correctly, by simulating
# what install-app.sh does with a local directory:
#   cp -r <src> apps/<APP> ; rm -rf .git ; write .pth ; import the module
# Done against a SCRATCH path so the live install is untouched.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

SRC=/tmp/hostfork-test          # exact copy of the host ./repos/robotics_lab
SCRATCH=/tmp/scratch-install
APP=robotics_lab

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cp -r "$SRC/." "$SCRATCH/$APP/"
rm -rf "$SCRATCH/$APP/.git"

echo "== 1. pth target derived from the host tree (same logic as install-app.sh) =="
HP=$(find "$SCRATCH/$APP" -maxdepth 3 -name 'hooks.py' 2>/dev/null | head -n1)
PTH_TARGET=$(dirname "$(dirname "$HP")")
echo "  hooks.py     : ${HP#$SCRATCH/}"
echo "  pth target   : $PTH_TARGET"

echo
echo "== 2. is that the valid package root (has hooks.py + __init__.py)? =="
[ -f "$PTH_TARGET/hooks.py" ] && echo "  hooks.py present" || echo "  MISSING hooks.py"
[ -f "$PTH_TARGET/__init__.py" ] && echo "  __init__.py present" || echo "  MISSING __init__.py"

echo
echo "== 3. can the module be imported with that pth target on sys.path? =="
PYTHONPATH="$PTH_TARGET" python3 - <<'PY'
import importlib, sys
mods = [
    "robotics_lab",
    "robotics_lab.hooks",
    "robotics_lab.robotics_lab.doctype.device.device",
]
for m in mods:
    try:
        importlib.import_module(m)
        print(f"  OK   {m}")
    except Exception as e:
        print(f"  FAIL {m}: {type(e).__name__}: {e}")
PY

echo
echo "== 4. does device.json parse and carry the expected fields? =="
python3 - <<'PY'
import json, glob
p = "/tmp/scratch-install/robotics_lab/robotics_lab/robotics_lab/doctype/device/device.json"
d = json.load(open(p))
print("  name          :", d["name"])
print("  module        :", d["module"])
print("  autoname      :", d["autoname"])
print("  field count   :", len(d["fields"]))
print("  computed flds :", [f["fieldname"] for f in d["fields"] if f.get("read_only")])
print("  permissions   :", [(x["role"], x.get("read"), x.get("write"), x.get("delete")) for x in d["permissions"]])
PY

echo
echo "== 5. module dir contents (is the layout clean?) =="
MD="$SCRATCH/$APP/$APP"
echo "  $MD:"
ls -1 "$MD" | sed 's/^/    /'

echo
echo "== 6. cleanup scratch =="
rm -rf "$SCRATCH" && echo "  removed $SCRATCH"
