"""Pass stdin to stdout untouched and keep a running byte offset in a file.

`x_install_runner.sh attach` pipes the pod's log through this. When the connection
drops it reconnects at the saved offset, so nothing is shown twice or skipped.

Usage: stream_counter.py <offset file> <starting offset>
"""

import os
import sys


def main() -> int:
    path, offset = sys.argv[1], int(sys.argv[2])
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            return 0
        view = memoryview(chunk)
        while view:
            view = view[os.write(1, view):]
        offset += len(chunk)
        with open(path, "w") as fh:
            fh.write(str(offset))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
