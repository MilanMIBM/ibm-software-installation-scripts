"""In zsh, $0 inside a function is the function's name, so `usage() { sed ... "$0"; }` reads a file named
'usage' and --help prints "sed: usage: No such file or directory" (seen live on the operator x.0, 2026-11-18).
Operator-mode scripts read the script path from ZSH_ARGZERO instead."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "scripts" / "install_confluent_platform"
FUNC_WITH_ARGZERO0 = re.compile(r'^\s*[A-Za-z_][\w-]*\(\)\s*\{[^}\n]*"\$0"', re.MULTILINE)


def test_no_function_reads_dollar_zero_as_the_script_path():
    bad = [f"{p.relative_to(ROOT)}:{text.count(chr(10), 0, m.start()) + 1}"
           for p in sorted(ROOT.rglob("*.sh"))
           for text in [p.read_text(errors="replace")]
           for m in FUNC_WITH_ARGZERO0.finditer(text)]
    assert bad == []
