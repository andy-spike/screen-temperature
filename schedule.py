#!/usr/bin/env python3
"""Store the Screen Temperature plugin schedule."""

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

DEFAULT = {"enabled": True, "from": "19:00", "to": "04:00", "temperature": 4000}


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.chmod(temporary, path.stat().st_mode if path.exists() else 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_state(path):
    # A file written by an older version can be missing keys, so fill the gaps.
    if path.exists():
        return DEFAULT | json.loads(path.read_text())
    return DEFAULT.copy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, default=Path.home() / ".config/omarchy/screen-temperature.json")
    parser.add_argument("--set", action="store_true")
    parser.add_argument("--enabled", choices=("true", "false"))
    parser.add_argument("--temperature", type=int)
    parser.add_argument("--from", dest="warm_from")
    parser.add_argument("--to", dest="normal_at")
    args = parser.parse_args()

    if args.set:
        if None in (args.enabled, args.temperature, args.warm_from, args.normal_at):
            parser.error("--set requires --enabled, --temperature, --from, and --to")
        if not 1000 <= args.temperature <= 6500:
            parser.error("temperature must be between 1000 and 6500")
        for label, clock in (("from", args.warm_from), ("to", args.normal_at)):
            if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", clock):
                parser.error(f"{label} must use 24-hour HH:MM")
        state = {
            "enabled": args.enabled == "true",
            "temperature": args.temperature,
            "from": args.warm_from,
            "to": args.normal_at,
        }
        write_atomic(args.state, json.dumps(state, indent=2) + "\n")
    else:
        state = read_state(args.state)
        if not args.state.exists():
            write_atomic(args.state, json.dumps(state, indent=2) + "\n")

    print(json.dumps(state))


if __name__ == "__main__":
    main()
