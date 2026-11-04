"""Runner tests that need a built runner image: IR_TEST_IMAGE=<image> pytest ...

Skipped otherwise. They need podman and take minutes under emulation, so they run
on demand and after an olm-utils patch bump, not on every test run. Neither touches
the shared olm-utils container or a cluster.
"""

import os
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
IMAGE = os.environ.get("IR_TEST_IMAGE", "")

pytestmark = pytest.mark.skipif(not IMAGE, reason="set IR_TEST_IMAGE to a built runner image")


def test_lifecycle_in_the_image():
    files = subprocess.check_output(["git", "ls-files", "-z", "-c", "-o", "--exclude-standard"], cwd=REPO)
    existing = b"\0".join(f for f in files.split(b"\0") if f and (REPO / f.decode()).is_file())
    tar = subprocess.run(["tar", "--null", "-T", "-", "-cf", "-"], input=existing, cwd=REPO, capture_output=True,
                         env={**os.environ, "COPYFILE_DISABLE": "1"}, check=True)
    result = subprocess.run(
        ["podman", "run", "-i", "--rm", "--timeout", "540", "--platform", "linux/amd64", "--user", "54321:0",
         "--tmpfs", "/work:mode=1777", "--entrypoint", "bash", IMAGE, "-c",
         "mkdir -p /tmp/repo && tar -xf - -C /tmp/repo && bash /tmp/repo/tests/install_runner_container_test.sh"],
        input=tar.stdout, capture_output=True, check=False)
    assert result.returncode == 0, result.stdout.decode(errors="replace")[-4000:]


def test_whole_path_with_a_container_as_the_pod():
    result = subprocess.run(["zsh", str(REPO / "tests/install_runner_e2e.sh"), IMAGE], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout[-4000:]
