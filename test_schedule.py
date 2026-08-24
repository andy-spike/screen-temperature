#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import schedule


def main():
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "screen-temperature.json"

        assert schedule.read_state(target) == schedule.DEFAULT

        state = {"enabled": False, "from": "18:30", "to": "05:15", "temperature": 3400}
        schedule.write_atomic(target, json.dumps(state))
        assert schedule.read_state(target) == schedule.DEFAULT | state

        schedule.write_atomic(target, json.dumps({"temperature": 2500}))
        assert schedule.read_state(target) == schedule.DEFAULT | {"temperature": 2500}

        completed = subprocess.run(
            [
                sys.executable,
                schedule.__file__,
                "--state",
                str(target),
                "--set",
                "--enabled",
                "false",
                "--active",
                "true",
                "--override-until",
                "0",
                "--temperature",
                "3000",
                "--from",
                "18:30",
                "--to",
                "05:15",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        manual = {
            "enabled": False,
            "active": True,
            "overrideUntil": 0,
            "temperature": 3000,
            "from": "18:30",
            "to": "05:15",
        }
        assert json.loads(completed.stdout) == manual
        assert schedule.read_state(target) == manual

        # read_state must not hand out the shared DEFAULT dict.
        schedule.read_state(Path(directory) / "absent.json")["temperature"] = 1
        assert schedule.DEFAULT["temperature"] == 4000


if __name__ == "__main__":
    main()
