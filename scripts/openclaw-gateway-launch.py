#!/usr/bin/python3
import os
import sys


OPENCLAW_PATH = "/usr/local/libexec/openclaw"
EX_CONFIG = 78


def main() -> int:
    check_only = sys.argv[1:] == ["--check"]
    if sys.argv[1:] and not check_only:
        return 64
    try:
        if not os.path.isfile(OPENCLAW_PATH) or not os.access(OPENCLAW_PATH, os.X_OK):
            raise RuntimeError("OpenClaw executable rejected")
    except Exception:
        print("OpenClaw gateway executable validation failed.", file=sys.stderr)
        return EX_CONFIG
    if check_only:
        print("OpenClaw gateway executable validation succeeded.")
        return 0
    os.execve(
        OPENCLAW_PATH,
        [
            OPENCLAW_PATH,
            "gateway",
            "run",
            "--bind",
            "loopback",
            "--port",
            "18789",
        ],
        os.environ.copy(),
    )
    return EX_CONFIG


if __name__ == "__main__":
    raise SystemExit(main())
