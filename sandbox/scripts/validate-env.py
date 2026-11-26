#!/usr/bin/env python3
"""Report demo-default passwords and refuse them in production mode."""

import argparse
import os
import sys
from pathlib import Path


DEMO_DEFAULTS = {
    "DB_ROOT_PASSWORD": "admin",
    "ERPNEXT_ADMIN_PASSWORD": "admin",
    "METABASE_DB_PASS": "metabase_demo_2026",
    "METABASE_ADMIN_PASSWORD": "DemoPass2026!",
}
PLACEHOLDER = "__FILL_ME__"


def read_env(path: Path) -> dict[str, str]:
    values = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if value and value[0] in "\"'":
            quote = value[0]
            for index in range(1, len(value)):
                if value[index] == quote and value[index - 1] != "\\":
                    suffix = value[index + 1 :].strip()
                    if not suffix or suffix.startswith("#"):
                        value = value[1:index]
                    break
        else:
            value = value.split(" #", 1)[0].rstrip()
        values[key] = value
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    args = parser.parse_args()
    if not args.env_file.is_file():
        parser.error(f"environment file not found: {args.env_file}")

    values = read_env(args.env_file)
    for key in (*DEMO_DEFAULTS, "ENVIRONMENT"):
        if key in os.environ:
            values[key] = os.environ[key]
    environment = values.get("ENVIRONMENT", "development").strip().lower()
    unsafe = [
        key
        for key, default in DEMO_DEFAULTS.items()
        if not values.get(key) or values[key] in {default, PLACEHOLDER}
    ]

    print(f"startup policy: ENVIRONMENT={environment}")
    if unsafe:
        print("demo-default credentials in use: " + ", ".join(unsafe))
    else:
        print("demo-default credentials in use: none")

    if environment == "production" and unsafe:
        print(
            "ERROR: production startup refused; replace: " + ", ".join(unsafe),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
