#!/usr/bin/env python3

import json
import tempfile
from pathlib import Path

import schedule


def main():
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "screen-temperature.json"

        assert schedule.read_state(target) == schedule.DEFAULT

        state = {"enabled": False, "from": "18:30", "to": "05:15", "temperature": 3400}
        schedule.write_atomic(target, json.dumps(state))
        assert schedule.read_state(target) == state

        schedule.write_atomic(target, json.dumps({"temperature": 2500}))
        assert schedule.read_state(target) == schedule.DEFAULT | {"temperature": 2500}

        # read_state must not hand out the shared DEFAULT dict.
        schedule.read_state(Path(directory) / "absent.json")["temperature"] = 1
        assert schedule.DEFAULT["temperature"] == 4000


if __name__ == "__main__":
    main()
