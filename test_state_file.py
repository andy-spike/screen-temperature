#!/usr/bin/env python3

import os
import pathlib
import subprocess
import tempfile


HELPER = pathlib.Path(__file__).with_name("state_file.py")


def run(*arguments, timeout=2):
    return subprocess.run(
        ["python3", HELPER, *arguments], capture_output=True, timeout=timeout, check=False
    )


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    state = root / "state.json"
    contents = '{"active":true,"temperature":4000}\n'

    assert run("write", state, contents).returncode == 0
    result = run("read", state)
    assert result.returncode == 0 and result.stdout == contents.encode()

    oversized = root / "oversized.json"
    oversized.write_bytes(b"x" * 4097)
    assert run("read", oversized).returncode != 0
    assert oversized.stat().st_size == 4097

    missing = root / "missing.json"
    assert run("read", missing).returncode != 0 and not missing.exists()

    fifo = root / "fifo.json"
    os.mkfifo(fifo)
    assert run("read", fifo).returncode != 0

    link = root / "link.json"
    link.symlink_to(state)
    assert run("read", link).returncode != 0

    assert run("write", state, "not json").returncode != 0
    assert state.read_text() == contents

print("test_state_file.py: PASS")
