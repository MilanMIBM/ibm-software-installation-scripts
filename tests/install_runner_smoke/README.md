# Runner smoke test

A test-only install module for the in-cluster install runner. Its chain, `full_smoke_chain.sh`, walks the whole runner path without installing anything: the hand-off, staging, the supervisor, the step journal, a step that warns on purpose, attach and collect.

- It only reads the cluster: `oc whoami`, `oc get namespaces`, `oc auth can-i`, `helm list` and an Ansible `k8s_info`.
- It only writes files in its own snapshot, on the runner pod's volume: `configs/smoke_config/result.txt` and `service_instances/install_runner_smoke/result.json`.
- It runs only in a runner pod. A local run (`INSTALL_RUN_MODE=local`) stops before its first step, so it never reaches the local podman or `cpd-cli`.

The runner finds this module only when `IR_MODULE_DIRS` names this folder. Without that variable it is never listed, offered or auto-detected as an install.

Offline test (fakes only, no cluster): `./.venv/bin/python -m pytest -q tests/test_install_runner_smoke.py`

## Run it live

The live run creates a runner slot (`install-runner-smoke`), with a cluster-admin binding while the run lasts, and builds the runner image if it is missing. Use a cluster where that is fine.

1. Copy the config next to the other configs of that cluster:
   - flat layout: `cp -R tests/install_runner_smoke/smoke_config configs/smoke_config`
   - multi-cluster mode: `cp -R tests/install_runner_smoke/smoke_config configs/clusters/<name>/smoke_config`

   Edit the copy for that cluster if needed: `STG_CLASS_BLOCK` (the runner volume's storage class), `OLM_UTILS_IMAGE` (the runner image's base) and `SMOKE_LONG_SECONDS` (default 240). The copy is staged into the pod, so its values reach the run.
2. Log in, and give the smoke config the cluster and the login from the environment. It holds no credentials itself:

   ```zsh
   export IR_MODULE_DIRS=tests/install_runner_smoke
   export SMOKE_OCP_URL="https://api.<cluster>:6443"
   export SMOKE_OC_LOGIN='oc login --server=https://api.<cluster>:6443 --token=<token>'
   ```

   `OCP_URL` and `OC_LOGIN` work too, when the shell has no other config loaded.
3. Launch it. It hands over to the pod and watches; Ctrl-C only detaches:

   ```zsh
   tests/install_runner_smoke/full_smoke_chain.sh                # every step
   tests/install_runner_smoke/full_smoke_chain.sh --skip long    # quicker
   ```

   Add `--target-cluster <name>` in multi-cluster mode.
4. Watch, collect and clean up, with the same `IR_MODULE_DIRS`:

   ```zsh
   scripts/install_runner/x_install_runner.sh status --install smoke
   scripts/install_runner/x_install_runner.sh attach --install smoke
   scripts/install_runner/x_install_runner.sh collect --install smoke
   scripts/install_runner/x_install_runner.sh teardown --install smoke
   ```

   The run ends `completed-with-warnings`: that is the `warn` step. Collect brings back `result.txt` into the config copy and `install_runner_smoke/result.json` into `service_instances/`. Delete both afterwards, along with the config copy.
