# Data Product Hub community access

Data Product Hub (DPH) requires both a Software Hub platform role and membership
in the hub community. Installing DPH and assigning a platform role alone do not
add a user to the community. The service must already be initialized.

`scripts/install_cloud_pak_for_data/5_component_specific_scripts/cp4d_general/5_add_dph_member.sh`
adds existing users or Software Hub groups to that community. It discovers the
existing default hub catalog through the API; no catalog ID is configured.

## Environment and authentication

The shell entry point uses the repository's `env_bootstrap.sh`, which loads the
selected cluster's CPD configuration, including `cpd_instance_details.sh`.
Run it directly; no separate environment file needs to be sourced. The shared
`--target-cluster` and `--env-target` options work through the bootstrap.

The Python helper uses the existing `SoftwareHub.sign_in` implementation:
`CPD_URL`, `CPD_USERNAME`, and `CPD_APIKEY`, with `CPD_PASSWORD` as a fallback.
It obtains a bearer token from `/icp4d-api/v1/authorize` and uses the Software Hub
HTTP API. The configured account must be a community/catalog administrator.
An OpenShift login or a `cpd-cli` profile is not needed for these API calls.
TLS certificate verification is disabled, matching the repository's CPD API
shell helper. Credentials are not passed as command-line arguments or printed.

## Add users

From the repository root:

```sh
dph_member=scripts/install_cloud_pak_for_data/5_component_specific_scripts/cp4d_general/5_add_dph_member.sh

zsh "$dph_member" --user person@example.com --role viewer --dry-run
zsh "$dph_member" --user person@example.com --role viewer

zsh "$dph_member" \
  --user first@example.com --user second@example.com --role editor
```

`--user` takes the existing Software Hub username, which may be an email address.
Repeat `--user` for multiple people. All additions in one run use the explicit
`--role`; split the calls when people need different roles.

| `--role` | Community access | Corresponding platform role |
| --- | --- | --- |
| `viewer` | Consumer: discover and consume data products | Data Product Consumer |
| `editor` | Producer: create/provide data products, plus consumer access | Data Product Provider |
| `admin` | Community administrator | Data Product Hub Administrator |

Community membership does not grant Software Hub platform administrator access.
Data products, delivery methods and source systems can impose further access
requirements.

## Use a group for ongoing access

Use a dedicated Software Hub group to manage DPH access without granting general
platform administrator privileges:

1. In **Access control**, create a group such as **DPH Consumers**.
2. Assign the group the **Data Product Consumer** platform role and add its users.
3. Add the group to the hub community once:

   ```sh
   zsh "$dph_member" --group "DPH Consumers" --role viewer --dry-run
   zsh "$dph_member" --group "DPH Consumers" --role viewer
   ```

Manage future users through the group's membership. For people who publish data
products, use a group such as **DPH Providers**, the **Data Product Provider**
platform role, and community role `editor`. Reserve `admin` for community
administrators. `--group` accepts an existing group name or numeric ID and can
be repeated. `--user` and `--group` cannot be mixed in one call.

## Behavior and limits

- The script only adds community members. It does not create users or groups,
  assign platform roles, change group membership, initialize DPH, or install it.
- Existing community members keep their current role, including when the
  requested role differs. Use **Manage community** to change existing roles.
- All requested identities are resolved before additions start. Additions are
  then verified individually. A later API failure can leave earlier additions
  applied; rerunning preserves those existing memberships.
- `--dry-run` authenticates and reads the API but makes no membership changes.
  The shared environment bootstrap still performs its normal local setup.
- Missing or uninitialized hub catalogs and unavailable backend services need
  separate investigation; granting membership does not repair those services.

IBM's [post-installation setup](https://www.ibm.com/docs/en/software-hub/5.4.x?topic=hub-post-installation-setup)
describes the platform role and community membership requirements. In the UI,
community administrators manage collaborators under **Administration >
Configurations and settings > Data Product Hub > Manage community**.

## Troubleshooting: missing Redis certificate

On DPH 5.4.6, repeated `redis.crt (No such file or directory)` and
`Cannot reconnect` errors in `dataproduct-api` logs can occur even while its pod
reports ready. Restarting the DPH API deployment may restore service temporarily:

```sh
oc rollout restart deployment/dataproduct-api -n cpd-operands
oc rollout status deployment/dataproduct-api -n cpd-operands --timeout=180s
```

Replace `cpd-operands` if your instance uses another operand namespace. This
briefly interrupts DPH API requests. Afterward, check the new pod's logs and test
creating and subscribing to a data product. The errors can recur after another
Redis disconnect; a successful rollout does not establish a permanent fix.

