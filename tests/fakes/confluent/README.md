# Fake cluster tools for the Confluent operator-mode tests

`fake_tool.py` is one Python script that a test copies (or symlinks) into a temp `bin/` under the names
`oc`, `kubectl`, `helm`, `curl`, `confluent`, `podman`, `skopeo` and `sleep`, first on `PATH`
(keep `/usr/bin:/bin` after it for openssl, base64, sed, awk and python3). The name it runs under decides
what it does. Nothing reaches a cluster or the network. Contract: implementation-contract.md §7.2.

| Env var | Meaning |
|---|---|
| `FAKE_LOG` | every call appends `<tool> <shell-quoted argv>` (stdin is not recorded) |
| `FAKE_RESPONSES` | JSON file: a list of `{"tool": "oc", "match": "<regex>", "stdout": "...", "stderr": "...", "rc": 0, "max": N}`; the regex is searched in the space-joined argv, the first match wins; `max` (optional) limits how often an entry answers (counted in `<FAKE_RESPONSES>.counts`), so a later entry can answer the next poll |
| `FAKE_OC_GET_DEFAULT` | unmatched `oc`/`kubectl` read verbs (`get describe explain whoami version auth api-resources`): `present` (default) = rc 0, empty stdout (identity runs); `absent` = rc 1 and `Error from server (NotFound)` on stderr, except with `--ignore-not-found` (rc 0, empty), as the real `oc` |

Defaults without a matching response:

- `oc`/`kubectl`: `login`, `project`, `whoami` rc 0; read verbs as above; every other verb (`apply create delete
  patch label annotate adm secrets exec rollout wait set scale replace ...`) rc 0 and counts as a **write** (tests
  assert "zero writes" by looking for these verbs in the log). Piped stdin is drained.
- `helm list` prints `[]` with `-o json`, else nothing; other helm verbs rc 0.
- `curl` rc 7 (connection refused); `confluent`, `podman`, `skopeo` rc 1; `sleep` returns at once (waits in the
  helpers count elapsed time per poll, so they still end).

Example (pytest):

```python
bin_dir = tmp_path / "bin"; bin_dir.mkdir()
for name in ("oc", "kubectl", "helm", "curl", "confluent", "podman", "skopeo", "sleep"):
    (bin_dir / name).symlink_to(FAKE_TOOL)
env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "FAKE_LOG": str(tmp_path / "calls.log"), "HOME": str(tmp_path)}
```
