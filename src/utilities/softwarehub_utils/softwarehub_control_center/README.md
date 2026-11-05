# Software Hub Control Center utilities

Day 1 tasks for a Control Center installed with [optional_install_swhub_control_center](../../../../scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/README.md). They read `configs/cp4d_config/swhub_control_center/`.

| Script | What it does |
| --- | --- |
| `toggle_cluster_admins.sh` | Gives OpenShift cluster-admins, or a list of users, Control Center roles. `on`, `off` or `status`. |
| `autodetect_instances.sh` | Finds every Software Hub instance on the cluster and adds it, setting up the cluster and account first. `--dry-run` only shows what it finds. |
| `list_control_center.sh` | Shows clusters, accounts and instances. Changes nothing. |
| `register_cluster.sh` | Registers the cluster. `--reauthenticate` prints the approval page again. |
| `create_account.sh` | Creates an account and allocates vCPU, memory and GPU. |
| `register_instance.sh` | Adds one instance to an account. |
| `remove_instance.sh` | Stops Control Center tracking an instance. The instance itself is not touched. |

`autodetect_instances.sh` runs at the end of the sub-install while `AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES` is true, which is the default. A failure there only warns, and you can re-run it on its own.

## Administrators

By default, only `cpadmin` can use Control Center. `toggle_cluster_admins.sh` gives every OpenShift cluster-admin the Control Center administrator role. It reads the cluster role bindings, so it covers any identity provider, people added through OpenShift groups, and people who have never signed in. It runs in the full install while `CONTROL_ADD_CLUSTER_ADMINS` is true, which is the default.

```bash
./toggle_cluster_admins.sh status      # who is covered and what they have; changes nothing
./toggle_cluster_admins.sh on          # grant, and set CONTROL_ADD_CLUSTER_ADMINS="true"
./toggle_cluster_admins.sh off         # remove those roles, and set it to "false"

# Specific users and roles instead of the cluster-admins; the toggle setting stays as it is
./toggle_cluster_admins.sh on --users a@example.com,b@example.com \
    --roles zen_administrator_role,zen_resource_group_admin_role
```

To make that permanent, set `CONTROL_ADMIN_USERS` and `CONTROL_ADMIN_ROLES`. With `CONTROL_ADMIN_USERS` set, only those users are covered, not the cluster-admins. `CONTROL_ADMIN_EXCLUDE_USERS` leaves people out.

- `off` removes only the listed roles and keeps each user's record and other roles. It works from the current cluster-admin list, so someone who has since lost cluster-admin keeps their role until you remove it with `off --users`.
- Control Center's sign-in user (`cpadmin`) is never changed, so the toggle can't lock you out.
- Nothing is watching for changes: a new cluster-admin gets the role the next time this runs.
- People can only sign in with OpenShift when OpenShift authentication is on for Control Center. The script warns if it isn't.

## The one browser step

Registering a cluster needs a person to approve Control Center's `cluster-reader` access, because the OAuth client uses `grantMethod: prompt`. The scripts print the page to open, then wait for up to `CONTROL_AUTODETECT_VERIFY_WAIT_SECONDS` (600 by default). If nobody approves in time, the script exits with a message, and the next run carries on from there.

IBM also asks you to re-authenticate when nodes are added or removed, and periodically unless the privileged monitoring service is installed. Use `register_cluster.sh --reauthenticate`.

## API keys

Control Center stores an API key for each instance. Generating a key revokes that user's previous one, so `autodetect_instances.sh` never does this unless you ask:

- The instance in `cpd_vars.sh` reuses `CPD_APIKEY` from `cpd_instance_details.sh`.
- Any other instance is skipped with the exact `register_instance.sh` command to run, unless you pass `--rotate-api-keys`, or set `CONTROL_AUTODETECT_ROTATE_API_KEYS=true`.

If a key is regenerated later, for example by re-running `3.3.1_get_instance_creds.sh`, Control Center loses access to that instance. Remove the instance and add it again with the new key.

## Default account

Auto-detected instances go into `CONTROL_AUTODETECT_ACCOUNT_NAME`. When `CONTROL_AUTODETECT_ACCOUNT_CPU` and `CONTROL_AUTODETECT_ACCOUNT_MEMORY_GI` are empty, it gets all of the workers' allocatable capacity, leaving nothing for other accounts. Set them if you plan to split the cluster.

## Not an IBM-published API

IBM documents these tasks only as web client steps. These scripts make the same calls as the web client, under `/zen-data/v1/management/platform` and `/zen-watchdog/v1/adminhubmon`, worked out from the zen 6.10.8 images. A future release can change them without notice, and IBM support may not help with them. If a script fails after an upgrade, the web client still works. All the calls are in `src/helpers/swhub_control_center_api_helpers.sh`.
