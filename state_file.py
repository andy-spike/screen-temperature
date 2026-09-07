#!/usr/bin/env python3
"""Bounded, descriptor-safe access to the screen-temperature state file."""

import json
import os
import stat
import sys
import tempfile


LIMIT = 4096


def read(path):
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > LIMIT:
            raise ValueError("state is not a bounded regular file")

        chunks = []
        remaining = LIMIT + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        contents = b"".join(chunks)
        if len(contents) > LIMIT:
            raise ValueError("state exceeds size limit")
        sys.stdout.buffer.write(contents)
    finally:
        os.close(descriptor)


def write(path, contents):
    encoded = contents.encode()
    if len(encoded) > LIMIT:
        raise ValueError("state exceeds size limit")

    # Validate before replacing the state, rather than leaving malformed JSON
    # that the next shell session would silently discard.
    json.loads(contents)
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(prefix=".screen-temperature.", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


def main():
    if len(sys.argv) < 3:
        raise ValueError("usage: state_file.py read PATH | write PATH CONTENTS")
    if sys.argv[1] == "read" and len(sys.argv) == 3:
        read(sys.argv[2])
    elif sys.argv[1] == "write" and len(sys.argv) == 4:
        write(sys.argv[2], sys.argv[3])
    else:
        raise ValueError("invalid arguments")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError):
        sys.exit(1)
