# Optional install: IBM Software Hub Control Center

Control Center manages resource use across the Software Hub instances on a cluster. It installs once per cluster, and needs an IBM Software Hub Premium entitlement. It is kept out of the regular component list. This folder installs it on its own, or as the last step of the main install.

## Run it

```bash
# 1. Write configs/cp4d_config/swhub_control_center/swhub_control_center_vars.sh
#    Derived from cpd_vars.sh if there is one, otherwise recommended values to fill in.
./0_swhub_control_center_generate_config.sh

# 2. Install
./full_installprocess-swhub_control_center.sh
```

You can also write the vars file from the `softwarehub_cp4d_vars_generation.py` notebook: select the Control Center checkbox and fill in the section that appears.

To chain it instead, set `INSTALL_SWHUB_CONTROL_CENTER="true"` in `cpd_vars.sh`. `full_swhub_x_cpd_installprocess.sh` then runs it after everything else, deriving the vars file first if it is missing. A failure there only warns: the main install is already done, and you can re-run this folder's full install on its own.

The full install takes `--from <step>`, `--skip <step>[,...]`, `--only <step>` and `--list-steps`.

| Step | Script | What it does |
| --- | --- | --- |
| `prep` | `1.0` | Checks prerequisites, creates the projects, downloads the CASE packages, applies their cluster-scoped resources |
| `shared-components` | `1.0.1` | License Service and scheduling service; only for a different cluster |
| `install` | `1.1` | `authorize-instance-topology`, then `setup-control-center` |
| `status` | `1.2` | `get-cr-status` and the `cpd-cli health` checks; a failure only warns |
| `instance-details` | `1.3` | Writes the URL and admin login to `swhub_control_center_instance_details.sh` |
| `oauth` | `1.4` | Creates the OAuth client and prints the values for registering the cluster |
| `cluster-admins` | utility | Gives OpenShift cluster-admins the Control Center admin role; a failure only warns |
| `autodetect-instances` | utility | Registers the cluster and adds every instance on it; a failure only warns |
| `other-workloads-indicator` | `x_debug_toggle_other_workloads_indicator.sh` | Stand-in instance that reports non-Software Hub reservations; follows `CONTROL_OTHER_WORKLOADS_INDICATOR`; needs the account autodetect makes, so it runs after it; a failure only warns |

`cluster-admins` and `autodetect-instances` run while `CONTROL_ADD_CLUSTER_ADMINS` and `AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES` are true, which is the default; the indicator step runs with autodetect. They and the other Day 1 scripts are in [softwarehub_control_center](../../../src/utilities/softwarehub_utils/softwarehub_control_center/README.md).

## How it stays separate from the regular install

`setup-control-center` is a stub in the standard olm-utils image, so these scripts use the premium image. They set `OLM_UTILS_IMAGE`, `OLM_UTILS_CONTAINER` and `CPD_CLI_MANAGE_WORKSPACE` for their own process only:

| | Regular install | Control Center |
| --- | --- | --- |
| Image | `olm-utils-v4:<VERSION>.<PATCH_ID>` | `olm-utils-premium-v4:<premium tag>` |
| Container | `olm-utils-play-v4` | `olm-utils-swhub-control-center` |
| Workspace | `~/cpd-cli` | `~/cpd-cli-swhub-control-center` |
| Config | `configs/cp4d_config/cpd_vars.sh` | `configs/cp4d_config/swhub_control_center/` |

Both can run at the same time without one recreating the other's container. On a shared cluster they share the local `oc` session. With a different cluster, the sub-install switches the local `oc` login, so don't run the two together.

## Staying on your patch level

The premium image is published under the release tag (`5.4.0.amd64`), which moves with each patch. The numbered patch tags stop early, so don't read them as the newest. The scripts always pass `--patch_id=${PATCH_ID}`: without it, `setup-control-center` installs the base release and re-applies older shared CRDs over your patched instance.

Keep `PATCH_ID` the same as the instances. `UPDATE=true` runs `setup-control-center --upgrade=true`; that path has not been tested yet.

## Instances on private routes

Control Center refuses instance URLs that resolve to a private address, and it checks from inside the cluster. On bare-metal clusters, routes resolve to the private ingress address there even when they are public from outside, so `autodetect_instances.sh` fails with `Access to private IP addresses is not allowed`. IBM does not document this check and there is no setting for it.

`x_debug_register_private_route_instances.sh` works around it: it briefly maps the routes to their public IP on `zen-core-api`, registers the instances, and removes the mapping. `--check` shows what each route resolves to and changes nothing. It is unsupported by IBM and restarts Control Center's API twice. The check only applies when adding an instance, so nothing needs to stay patched.

## Private registries

Point `CONTROL_OLM_UTILS_IMAGE` at your registry after mirroring the premium image, and add `ibm_swhcc` to `MIRROR_CPD_COMPONENTS` so its images are mirrored. Neither happens automatically.
