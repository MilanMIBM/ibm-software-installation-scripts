#!/bin/zsh
# =============================================================================
# confluent_scripts_mode_identity.sh - scripts-mode byte-identity harness
# -----------------------------------------------------------------------------
# Proves that the Confluent install scripts behave byte-identically to a
# baseline commit when CONFLUENT_DEPLOY_MODE=scripts is set explicitly.
#
# It snapshots two trees - the baseline (a git worktree of --baseline-ref,
# default 0efad5f) and the tree under test (default: this checkout, tracked +
# untracked-not-ignored files) - and runs the same list of side-effect-free
# probes in each. The tree under test runs with CONFLUENT_DEPLOY_MODE=scripts
# exported; the baseline runs without it. Outputs are normalised (repo and
# sandbox paths, mktemp names, timestamps, [TIMER] lines) and diffed.
#
# The generators and the notebook do not read the environment: they default to
# operator mode (plan O2). Their probes name scripts mode explicitly, on the
# tree under test only, through ${IDENTITY_GEN_ARGS} (0_confluent_...:
# --deploy-mode scripts), ${IDENTITY_NB_ARGS} (notebook: deploy_mode_select=
# scripts; the Flink operator source stays "follow", which resolves to helm),
# ${IDENTITY_J2_ARGS} (direct j2 render: confluent_deploy_mode=scripts
# flink_operator_source=helm) and the 'full-scripts' fixture (the Flink
# generator reads the platform mode from the file). All are empty / absent on
# the baseline side.
#
# Allowed differences (contract 1.1 / 7.3), nothing else: per probe, ALLOW_DELTA
# names which of these fixed texts the tree under test may add, each at most
# once and only in the named place - the toggle snippet in the j2 render after
# its anchor line, the toggle snippet appended (after a blank line) to
# confluent_vars.sh, the generator's one INFO line (or its --dry-run form), and
# the new flags' option lines in the two generators' --help.
# A probe that matches only after removing them is reported ALLOWED (a pass).
#
#   tests/confluent_scripts_mode_identity.sh              # run every probe
#   tests/confluent_scripts_mode_identity.sh --list       # print the probes
#   tests/confluent_scripts_mode_identity.sh --only gen-confluent-help,j2-notebook-default
#   tests/confluent_scripts_mode_identity.sh --current /path/to/other/tree
#
# Exit: 0 identical, 1 differences (a unified diff per probe is printed),
#       2 usage or setup error, 3 the baseline git worktree cannot be created.
#
# Safety: nothing here reads or writes the real configs/, $HOME or a cluster.
#   - Probes run in clones of the snapshots (one per worker and side, reset
#     after every probe: whatever a probe wrote outside configs/ is put back from
#     the snapshot), each time with fresh configs/ (fixtures), HOME, TMPDIR and
#     MCM_STATE_FILE and an environment that holds only what probe_env sets.
#   - A shim dir is first on PATH with fake oc, kubectl, helm, confluent,
#     podman, docker, skopeo, curl, wget, cpd-cli, kcat and ibmcloud: each logs
#     its argv to the probe's call log and exits 97, so no call reaches a
#     cluster or the network, and the call log is part of the diff.
#   - _CP4D_PREP_DONE=1 stops env_bootstrap.sh from running
#     0.0_make_executable.sh (chmod + podman machine start).
#   - Each probe has a timeout (IDENTITY_PROBE_TIMEOUT, default 30 s).
#
# Options (environment variable in brackets):
#   --baseline-ref REF   baseline commit [IDENTITY_BASELINE_REF, default 0efad5f]
#   --worktree DIR       where the baseline worktree lives; reused when it is a
#                        clean worktree of this repo at REF
#                        [IDENTITY_BASELINE_WT]
#   --current DIR        tree under test [IDENTITY_CURRENT_TREE, default: this
#                        checkout]. A git tree is snapshotted from git ls-files;
#                        any other directory is copied minus .git/configs/.venv.
#   --work DIR           scratch dir for snapshots and probe output
#                        [IDENTITY_WORK_DIR, default: a new mktemp dir]
#   --jobs N             probes run in parallel [IDENTITY_JOBS, default 8]
#   --only a,b           run only these probes (names from --list)
#   --keep               keep the scratch dir (it is always kept on a difference)
#   --list               print the probe list and exit
#   -h, --help           this text
#
# -----------------------------------------------------------------------------
# Adding a probe (later phases)
# -----------------------------------------------------------------------------
# Append one line to PROBES below:   "<name>|<fixtures>|<exit>|<command>"
#   name      unique, [a-z0-9.-]; shows in progress lines, --only and diffs
#   fixtures  '+'-joined config fixtures put into the probe's configs/ before
#             it runs (see FIXTURE): none, minimal, full, cpd, iceberg
#   exit      the exit code the BASELINE run must have, or '*'. A baseline that
#             exits otherwise marks the probe BROKEN (it no longer reaches the
#             code it was written for), which fails the run like a difference.
#   command   a zsh snippet run with `zsh -c` from the root of the probe's
#             repo clone. ${P} = scripts/install_confluent_platform,
#             ${PU} = its utility_scripts_confluent_platform, ${PF} = the Flink
#             addon dir, ${PFU} = the Flink utilities, ${CID} = a fixed 22-char
#             cluster id, ${IDENTITY_HELPERS} = the harness helper dir
#             (render_notebook.py). VAR=value prefixes and pipes work as in
#             any shell (everything after the third '|' is the command).
#             ${IDENTITY_SIDE} is "baseline" or "current", for a probe that must
#             name scripts mode explicitly on the tree under test only; the
#             ready-made forms are ${=IDENTITY_GEN_ARGS}, ${=IDENTITY_NB_ARGS} and
#             ${=IDENTITY_J2_ARGS} (empty on the baseline side), e.g.
#               ${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size small
#             (CONFLUENT_DEPLOY_MODE=scripts is already exported there).
#             Fixtures full-scripts / full-unquoted are 'full' plus the toggle
#             snippet / a bare `export CONFLUENT_DEPLOY_MODE=scripts` line.
# A probe whose scripts-mode output legitimately gains the toggle snippet gets
# an ALLOW_DELTA entry (below PROBES); every other difference fails.
# A probe must be side-effect free outside its sandbox: read the script first
# and only add commands that exit before any oc/helm call, or whose calls hit
# the fake shims deterministically (they then show up in the call log). Check a
# new probe for determinism by running the harness with --current pointing at
# the baseline worktree: it must report IDENTICAL against itself.
# =============================================================================

emulate -L zsh
setopt pipe_fail no_nomatch extended_glob
unsetopt err_exit

typeset -r HARNESS_FILE="${0:A}"
typeset -r HARNESS_DIR="${HARNESS_FILE:h}"
typeset -r HARNESS_REPO="${HARNESS_DIR:h}"

P=scripts/install_confluent_platform
PU=${P}/utility_scripts_confluent_platform
PF=${P}/install_confluent_platform_flink_addon
PFU=${PF}/utility_scripts_confluent_flink
CID=IdentityHarnessCID0001

# -----------------------------------------------------------------------------
# Probes: "<name>|<fixtures>|<exit>|<command>" - see the header for how to add one.
# Single-quoted, so ${P}, ${CID}, ... expand inside the probe's own shell.
# Fields: name|fixtures|baseline exit code (or *)|command.
# -----------------------------------------------------------------------------
PROBES=(
    # --- full install chains: step plans (h_steps_parse / h_steps_plan) -----
    'chain-platform-list-steps-minimal|minimal|0|${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-platform-list-steps-full|full|0|${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-platform-list-steps-select|full|0|${P}/full_installprocess-confluent_platform.sh --list-steps --from install --skip status,flink'
    'chain-platform-list-steps-only|full|0|${P}/full_installprocess-confluent_platform.sh --list-steps --instance-details'
    'chain-platform-list-steps-toggles|full|0|DO_FLINK_ADDON=false DO_CONFLUENT_PREP=false ${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-platform-list-steps-iceberg|full|1|DO_ICEBERG_WATSONX_SETUP=true ${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-platform-list-steps-iceberg-config|full+iceberg|0|DO_ICEBERG_WATSONX_SETUP=true ${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-platform-bad-step|full|1|${P}/full_installprocess-confluent_platform.sh --list-steps --skip nosuchstep'
    'chain-platform-help|full|0|${P}/full_installprocess-confluent_platform.sh --help'
    'chain-platform-no-config|none|1|${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-flink-list-steps-full|full|0|${PF}/full_installprocess-confluent_flink.sh --list-steps'
    'chain-flink-list-steps-select|full|0|${PF}/full_installprocess-confluent_flink.sh --list-steps --from install --skip status'
    'chain-flink-list-steps-minimal|minimal|1|${PF}/full_installprocess-confluent_flink.sh --list-steps'
    'chain-flink-help|full|0|${PF}/full_installprocess-confluent_flink.sh --help'

    # --- vars generators (write only into the probe's configs/) -------------
    'gen-confluent-help|none|0|${P}/0_confluent_prepare_template_config.sh --help'
    'gen-confluent-dryrun-xsmall|none|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size xsmall --cluster-id ${CID} --dry-run'
    'gen-confluent-dryrun-small|none|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --cluster-id ${CID} --dry-run'
    'gen-confluent-dryrun-medium|none|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size medium --cluster-id ${CID} --dry-run'
    'gen-confluent-dryrun-large|none|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size large --cluster-id ${CID} --dry-run'
    'gen-confluent-dryrun-full|full|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size large --dry-run'
    'gen-confluent-write-empty|none|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --cluster-id ${CID}'
    'gen-confluent-write-seeded|cpd|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --cluster-id ${CID}'
    'gen-confluent-write-overrides|cpd|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size xsmall --cluster-id ${CID} --brokers 2 --replication-factor 2 --partitions 6 --storage 50Gi --storage-class identity-sc --broker-cpu-limit 3 --component-mem-limit 3Gi'
    'gen-confluent-rewrite-full|full|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size medium --partitions 12'
    'gen-confluent-rewrite-keep-id|full|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size small --overwrite-cluster-id false'
    'gen-confluent-bad-size|none|1|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --size huge'
    'gen-confluent-bad-arg|none|1|${P}/0_confluent_prepare_template_config.sh --no-such-flag'
    'gen-flink-help|none|0|${PF}/0_flink_prepare_template_config.sh --help'
    'gen-flink-dryrun-full|full-scripts|0|${PF}/0_flink_prepare_template_config.sh --size large --dry-run'
    'gen-flink-write-after-confluent|cpd|0|${P}/0_confluent_prepare_template_config.sh ${=IDENTITY_GEN_ARGS} --cluster-id ${CID} >/dev/null && ${PF}/0_flink_prepare_template_config.sh --size medium'
    'gen-flink-rewrite-full|full-scripts|0|${PF}/0_flink_prepare_template_config.sh --size xsmall --namespace confluent --task-slots 3'
    'gen-flink-no-config|none|1|${PF}/0_flink_prepare_template_config.sh'
    'gen-flink-bad-arg|none|1|${PF}/0_flink_prepare_template_config.sh --no-such-flag'
    # the file alone selects scripts mode: a bare (unquoted) export line, no flag, no env
    'gen-confluent-rewrite-unquoted|full-unquoted|0|${P}/0_confluent_prepare_template_config.sh --size medium'
    'gen-flink-rewrite-unquoted|full-unquoted|0|${PF}/0_flink_prepare_template_config.sh --size xsmall'
    'chain-platform-list-steps-unquoted|full-unquoted|0|unset CONFLUENT_DEPLOY_MODE; ${P}/full_installprocess-confluent_platform.sh --list-steps'
    'chain-flink-list-steps-unquoted|full-unquoted|0|unset CONFLUENT_DEPLOY_MODE; ${PF}/full_installprocess-confluent_flink.sh --list-steps'

    # --- notebook j2 render (confluent_platform_vars_generation.py run headless) ---
    'j2-notebook-default|none|0|python3 ${IDENTITY_HELPERS}/render_notebook.py ${=IDENTITY_NB_ARGS}'
    'j2-notebook-no-flink|none|0|python3 ${IDENTITY_HELPERS}/render_notebook.py ${=IDENTITY_NB_ARGS} include_flink_checkbox=false'
    'j2-notebook-security-off|none|0|python3 ${IDENTITY_HELPERS}/render_notebook.py ${=IDENTITY_NB_ARGS} auth_enabled_checkbox=false sasl_enabled_checkbox=false mds_enabled_checkbox=false external_kafka_enabled_checkbox=false'
    'j2-notebook-routes-off|none|0|python3 ${IDENTITY_HELPERS}/render_notebook.py ${=IDENTITY_NB_ARGS} create_routes_checkbox=false flink_create_routes_checkbox=false'
    # --- the j2 template alone, fixed context (WP-B: tests/fixtures/confluent_j2_context.json) ---
    'j2-template-render|none|0|python3 ${IDENTITY_HELPERS}/render_j2.py ${IDENTITY_HELPERS}/confluent_j2_context.json ${=IDENTITY_J2_ARGS}'

    # --- install steps: stop at their first (fake) cluster call ------------
    'step-1.0-prep-help|full|0|${P}/1.0_confluent_prep.sh --help'
    'step-1.0-prep|full|97|${P}/1.0_confluent_prep.sh'
    'step-1.1-install|full|1|${P}/1.1_confluent_install.sh'
    'step-1.2-status|full|1|${P}/1.2_confluent_status.sh'
    'step-1.3-instance-details|full|1|${P}/1.3_confluent_get_instance_details.sh'
    'step-flink-1.0-prep-help|full|0|${PF}/1.0_flink_prep.sh --help'
    'step-flink-1.0-prep-dryrun|full|97|${PF}/1.0_flink_prep.sh --dry-run'
    'step-flink-1.1-install-help|full|0|${PF}/1.1_flink_install.sh --help'
    'step-flink-1.1-install-dryrun|full|1|${PF}/1.1_flink_install.sh --dry-run'
    'step-flink-1.2-status-help|full|0|${PF}/1.2_flink_status.sh --help'
    'step-flink-1.2-status|full|0|${PF}/1.2_flink_status.sh'
    'step-flink-1.3-instance-details|full|1|${PF}/1.3_flink_get_instance_details.sh'
    'cli-login-help|full|0|zsh ${P}/confluent_cli_login.sh --help'
    'cli-login-no-details|full|1|zsh ${P}/confluent_cli_login.sh --status'

    # --- platform utilities: --help, and --dry-run up to the first fake oc call ---
    'x.0-uninstall-help|full|0|${PU}/x.0_confluent_uninstall.sh --help'
    'x.0-uninstall-dryrun|full|0|${PU}/x.0_confluent_uninstall.sh --dry-run'
    'x.0-uninstall-dryrun-keep|full|0|${PU}/x.0_confluent_uninstall.sh --dry-run --keep-data --keep-project'
    'x.1-reinstall-help|full|0|${PU}/x.1_confluent_reinstall.sh --help'
    'x.1-reinstall-dryrun|full|1|${PU}/x.1_confluent_reinstall.sh --dry-run'
    'x.2-add-auth-help|full|0|${PU}/x.2_confluent_add_auth.sh --help'
    'x.2-add-auth-dryrun|full|1|${PU}/x.2_confluent_add_auth.sh --dry-run'
    'x.2-add-auth-openshift-help|full|0|${PU}/x.2_confluent_add_auth_openshift.sh --help'
    'x.2-add-auth-openshift-dryrun|full|1|${PU}/x.2_confluent_add_auth_openshift.sh --dry-run'
    'x.2-add-sasl-help|full|0|${PU}/x.2_confluent_add_sasl.sh --help'
    'x.2-add-sasl-dryrun|full|1|${PU}/x.2_confluent_add_sasl.sh --dry-run'
    'x.3-add-connector-help|full|0|${PU}/x.3_confluent_add_connector.sh --help'
    'x.3-add-connector-no-source|full|1|${PU}/x.3_confluent_add_connector.sh --dry-run'
    'x.3-add-connector-list|full|1|${PU}/x.3_confluent_add_connector.sh --list'
    'x.4-external-access-help|full|0|${PU}/x.4_confluent_add_external_access.sh --help'
    'x.4-external-access-dryrun|full|1|${PU}/x.4_confluent_add_external_access.sh --dry-run'
    'x.4-add-mds-help|full|0|${PU}/x.4_confluent_add_mds.sh --help'
    'x.4-add-mds-dryrun|full|1|${PU}/x.4_confluent_add_mds.sh --dry-run'
    'x.4-remove-mds-help|full|0|${PU}/x.4_confluent_remove_mds.sh --help'
    'x.4-remove-mds-dryrun|full|1|${PU}/x.4_confluent_remove_mds.sh --dry-run'
    'x.4-user-store-help|full|0|${PU}/x.4_confluent_user_store.sh --help'
    'x.4-user-store-dryrun|full|1|${PU}/x.4_confluent_user_store.sh --dry-run'
    'x.5-cert-to-vault-help|full|0|${PU}/x.5_confluent_add_cert_to_vault.sh --help'
    'x.5-cert-to-vault-dryrun|full|1|${PU}/x.5_confluent_add_cert_to_vault.sh --dry-run'
    'x.6-iceberg-help|full|0|${PU}/x.6_confluent_setup_iceberg_watsonx.sh --help'
    'x.6-iceberg-dryrun-no-config|full|1|${PU}/x.6_confluent_setup_iceberg_watsonx.sh --dry-run'
    'x.6-iceberg-dryrun|full+iceberg|1|${PU}/x.6_confluent_setup_iceberg_watsonx.sh --dry-run'

    # --- Flink utilities ------------------------------------------------------
    'flink-x.0-uninstall-help|full|0|${PFU}/x.0_flink_uninstall.sh --help'
    'flink-x.0-uninstall-dryrun|full|0|${PFU}/x.0_flink_uninstall.sh --dry-run'
    'flink-x.2-auth-openshift-help|full|0|${PFU}/x.2_flink_add_auth_openshift.sh --help'
    'flink-x.2-auth-openshift-dryrun|full|1|${PFU}/x.2_flink_add_auth_openshift.sh --dry-run'
    'flink-x.3-sample-job-help|full|0|${PFU}/x.3_flink_sample_job.sh --help'
    'flink-x.3-sample-job-dryrun|full|0|${PFU}/x.3_flink_sample_job.sh --dry-run'
    'flink-x.4-connect-kafka-help|full|0|${PFU}/x.4_flink_connect_kafka.sh --help'
    'flink-x.4-connect-kafka-dryrun|full|1|${PFU}/x.4_flink_connect_kafka.sh --dry-run'

    # --- private-registry mirroring hooks (fd 3 is their output) ---------------
    'mirror-prefill|full|0|ENV_TARGET=confluent zsh scripts/private_registry_mirroring/0_initial_setup/installs/confluent.sh prefill 3>&1'
    'mirror-prefill-minimal|minimal|0|ENV_TARGET=confluent zsh scripts/private_registry_mirroring/0_initial_setup/installs/confluent.sh prefill 3>&1'
    'mirror-map-images|full|0|ENV_TARGET=confluent MIRROR_CONFLUENT_COMPONENTS=broker,schema-registry,connect,ksqldb,rest-proxy,control-center,c3-gateway,ldap,keycloak,flink-runtime,flink-sql MIRROR_CONFLUENT_CONTENT=images,operators zsh scripts/private_registry_mirroring/1_map_content/installs/confluent.sh map 3>&1'
    'mirror-map-charts|full|0|ENV_TARGET=confluent MIRROR_CONFLUENT_COMPONENTS=flink-operator,flink-cmf MIRROR_CONFLUENT_CONTENT=images,charts zsh scripts/private_registry_mirroring/1_map_content/installs/confluent.sh map 3>&1'
)

# -----------------------------------------------------------------------------
# Allowed scripts-mode deltas (contract 1.1 / 7.3) - an explicit, narrow list.
# probe name -> comma-joined allowances; each removes its fixed text at most once
# from the tree under test's report, only in the named place:
#   j2-snippet   stdout: the 5-line toggle snippet directly after the j2 anchor
#                "# Topology from https://github.com/confluentinc/cp-all-in-one (KRaft variant)."
#   file-snippet configs/confluent_platform_config/confluent_vars.sh content: a
#                blank line + the toggle snippet (what 0_ appends); the same once
#                in confluent_vars.sh.bak, which the sizing splice copies from the
#                file after the toggle write
#   info-line    stdout: [INFO] CONFLUENT_DEPLOY_MODE="scripts" written to confluent_vars.sh.
#   dryrun-line  stdout: [INFO] --dry-run: would write CONFLUENT_DEPLOY_MODE="scripts" to <file>.
#                (the --dry-run form of info-line; <file> = confluent_vars.sh or its temp copy)
#   help-confluent / help-flink
#                stdout of the generator's --help: only the option/description
#                lines of the new flags (fixed text in allow.pl: --deploy-mode,
#                --switch-deploy-mode, --sasl-impl, --tls-source, --approval,
#                --kraft-replicas, --kraft-storage / --operator-source,
#                --cmf-resource-mode), once, right after "-h, --help" + blank
#                line; every other help line must match (lead decision 2026-11-18)
# -----------------------------------------------------------------------------
typeset -A ALLOW_DELTA=(
    gen-confluent-dryrun-xsmall       dryrun-line
    gen-confluent-dryrun-small        dryrun-line
    gen-confluent-dryrun-medium       dryrun-line
    gen-confluent-dryrun-large        dryrun-line
    gen-confluent-dryrun-full         dryrun-line
    gen-confluent-write-empty         info-line,file-snippet
    gen-confluent-write-seeded        info-line,file-snippet
    gen-confluent-write-overrides     info-line,file-snippet
    gen-confluent-rewrite-full        info-line,file-snippet
    gen-confluent-rewrite-keep-id     info-line,file-snippet
    gen-confluent-bad-size            info-line,file-snippet
    gen-confluent-help                help-confluent
    gen-flink-help                    help-flink
    gen-flink-write-after-confluent   file-snippet
    j2-notebook-default               j2-snippet
    j2-notebook-no-flink              j2-snippet
    j2-notebook-security-off          j2-snippet
    j2-notebook-routes-off            j2-snippet
    j2-template-render                j2-snippet
)


FAKE_COMMANDS=(oc kubectl helm confluent podman docker skopeo curl wget cpd-cli kcat ibmcloud)

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
BASELINE_REF="${IDENTITY_BASELINE_REF:-0efad5f}"
BASELINE_WT="${IDENTITY_BASELINE_WT:-/private/tmp/claude-501/-Users-milanmrdenovic-Documents-GitHub-ibm-software-installation-scripts/409cd12d-0db0-458d-a803-43f24e3637ee/scratchpad/identity-baseline-wt}"
CURRENT_TREE="${IDENTITY_CURRENT_TREE:-${HARNESS_REPO}}"
WORK="${IDENTITY_WORK_DIR:-}"
JOBS="${IDENTITY_JOBS:-8}"
PROBE_TIMEOUT="${IDENTITY_PROBE_TIMEOUT:-30}"
ONLY=""
KEEP=false
LIST=false

usage() { awk 'NR > 2 && /^# Adding a probe/ { exit } NR > 2 && /^#/ && !/^# [=-]{10,}/ { sub(/^# ?/, ""); print }' "${HARNESS_FILE}"; }
die() { print -r -- "[identity] ERROR: $*" >&2; exit 2; }
say() { print -r -- "[identity] $*"; }

while (( $# )); do
    case "$1" in
        --baseline-ref) BASELINE_REF="${2:?--baseline-ref needs a ref}"; shift 2 ;;
        --worktree)     BASELINE_WT="${2:?--worktree needs a dir}"; shift 2 ;;
        --current)      CURRENT_TREE="${2:?--current needs a dir}"; shift 2 ;;
        --work)         WORK="${2:?--work needs a dir}"; shift 2 ;;
        --jobs)         JOBS="${2:?--jobs needs a number}"; shift 2 ;;
        --only)         ONLY="${2:?--only needs probe names}"; shift 2 ;;
        --keep)         KEEP=true; shift ;;
        --list)         LIST=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option '$1' (see --help)" ;;
    esac
done
[[ "${JOBS}" == <1-> ]] || die "--jobs must be a positive number"
[[ "${PROBE_TIMEOUT}" == <1-> ]] || die "IDENTITY_PROBE_TIMEOUT must be a positive number"

# Probe table -> parallel arrays, with the --only filter applied.
typeset -a PNAME PFIX PEXIT PCMD
typeset -A _seen
for _line in "${PROBES[@]}"; do
    _f=("${(@s:|:)_line}")
    (( ${#_f} >= 4 )) || die "probe line needs name|fixtures|exit|command: ${_line}"
    _n="${_f[1]}"
    [[ "${_n}" == [a-z0-9.-]## ]] || die "probe name '${_n}' must be [a-z0-9.-]"
    (( ${+_seen[${_n}]} )) && die "probe '${_n}' is listed twice"
    [[ "${_f[3]}" == (<->|\*) ]] || die "probe '${_n}': exit must be a number or *"
    _seen[${_n}]=1
    PNAME+=("${_n}"); PFIX+=("${_f[2]}"); PEXIT+=("${_f[3]}"); PCMD+=("${(j:|:)_f[4,-1]}")
done
if [[ -n "${ONLY}" ]]; then
    typeset -a _keep_idx=()
    for _n in ${(s:,:)ONLY}; do
        (( ${PNAME[(Ie)${_n}]} )) || die "--only: no probe named '${_n}' (see --list)"
        _keep_idx+=(${PNAME[(Ie)${_n}]})
    done
    typeset -a _pn=() _pf=() _pe=() _pc=()
    for _i in ${(onu)_keep_idx}; do
        _pn+=("${PNAME[_i]}"); _pf+=("${PFIX[_i]}"); _pe+=("${PEXIT[_i]}"); _pc+=("${PCMD[_i]}")
    done
    PNAME=("${_pn[@]}"); PFIX=("${_pf[@]}"); PEXIT=("${_pe[@]}"); PCMD=("${_pc[@]}")
fi
TOTAL=${#PNAME}
for _n in ${(k)ALLOW_DELTA}; do
    (( ${+_seen[${_n}]} )) || die "ALLOW_DELTA names an unknown probe '${_n}'"
    for _f in ${(s:,:)ALLOW_DELTA[${_n}]}; do
        [[ "${_f}" == (j2-snippet|file-snippet|info-line|dryrun-line|help-confluent|help-flink) ]] || die "ALLOW_DELTA[${_n}]: unknown allowance '${_f}'"
    done
done
unset _line _f _n _seen _keep_idx _pn _pf _pe _pc _i

if ${LIST}; then
    for _i in {1..${TOTAL}}; do
        printf '%-42s %-13s exit=%-3s %s\n' "${PNAME[_i]}" "${PFIX[_i]}" "${PEXIT[_i]}" "${PCMD[_i]}"
    done
    exit 0
fi
(( JOBS > TOTAL )) && JOBS=${TOTAL}

# Builtins instead of processes: starting processes is the slow part on this kind of machine.
zmodload zsh/datetime zsh/zselect || die "zsh/datetime and zsh/zselect are needed"
zmodload -F zsh/files b:mkdir b:mv b:rm || die "zsh/files is needed"
typeset -F _t0=${EPOCHREALTIME}
elapsed() { printf '%.1fs' $(( EPOCHREALTIME - _t0 )); }

# -----------------------------------------------------------------------------
# Scratch dir
# -----------------------------------------------------------------------------
if [[ -z "${WORK}" ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/confluent-identity.XXXXXX")" || die "cannot create a scratch dir"
else
    mkdir -p "${WORK}" || die "cannot create ${WORK}"
    [[ -z "$(ls -A "${WORK}" 2>/dev/null)" ]] || die "--work ${WORK} is not empty"
fi
WORK="${WORK:A}"
_cleanup() { ${KEEP} || rm -rf "${WORK}"; }
trap _cleanup EXIT
_kill_jobs() {
    local v p
    for v in ${(v)jobstates}; do
        for p in ${(s.:.)v}; do [[ "${p}" == <->=* ]] && kill -TERM ${p%%=*} 2>/dev/null; done
    done
}
trap 'print -r -- "[identity] interrupted" >&2; _kill_jobs; exit 130' INT TERM

# Copies a tree's files (not .git, not ignored files) into DEST.
snapshot_tree() {   # SRC DEST
    local src="$1" dest="$2"
    mkdir -p "${dest}" || return 1
    if git -C "${src}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && [[ "$(git -C "${src}" rev-parse --show-toplevel 2>/dev/null)" == "${src:A}" ]]; then
        ( cd "${src}" && git ls-files -co --exclude-standard -z \
            | perl -0ne 'chomp; print "$_\0" if -e $_ || -l $_' \
            | tar -cf - --null -T - ) | tar -xpf - -C "${dest}" || return 1
    else
        ( cd "${src}" && tar -cf - --exclude ./.git --exclude ./configs --exclude ./.venv \
            --exclude '__pycache__' --exclude ./service_instances . ) | tar -xpf - -C "${dest}" || return 1
    fi
    # Python for the scripts' _vr_python and the notebook: the harness checkout's venv, shared read-only.
    [[ -n "${VENV_DIR}" ]] && ln -s "${VENV_DIR}" "${dest}/.venv"
    return 0
}

# Clone (APFS clonefile when available) of a snapshot, mtimes kept.
clone_tree() {   # SRC DEST
    cp -cRp "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -Rp "$1" "$2"; }
}

# -----------------------------------------------------------------------------
# Baseline worktree
# -----------------------------------------------------------------------------
GIT_REPO="$(git -C "${HARNESS_REPO}" rev-parse --show-toplevel 2>/dev/null)" \
    || { print -r -- "[identity] cannot use git in ${HARNESS_REPO}" >&2; exit 3; }
BASELINE_SHA="$(git -C "${GIT_REPO}" rev-parse --verify --quiet "${BASELINE_REF}^{commit}")" \
    || die "baseline ref '${BASELINE_REF}' is not a commit in ${GIT_REPO}"
BASELINE_WT="${BASELINE_WT:A}"

say "[prep] baseline ${BASELINE_REF} (${BASELINE_SHA[1,12]}) worktree ${BASELINE_WT}"
if [[ -e "${BASELINE_WT}" ]]; then
    _wt_common="$(git -C "${BASELINE_WT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    _repo_common="$(git -C "${GIT_REPO}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [[ -n "${_wt_common}" && "${_wt_common:A}" == "${_repo_common:A}" \
        && "$(git -C "${BASELINE_WT}" rev-parse --show-toplevel 2>/dev/null)" == "${BASELINE_WT}" ]] \
        || die "${BASELINE_WT} exists but is not a worktree of ${GIT_REPO} - remove it or pass --worktree"
    [[ -z "$(git -C "${BASELINE_WT}" status --porcelain 2>/dev/null)" ]] \
        || die "baseline worktree ${BASELINE_WT} has local changes - clean it or pass another --worktree"
    if [[ "$(git -C "${BASELINE_WT}" rev-parse HEAD)" != "${BASELINE_SHA}" ]]; then
        git -C "${BASELINE_WT}" checkout --quiet --detach "${BASELINE_SHA}" \
            || die "cannot move ${BASELINE_WT} to ${BASELINE_SHA}"
    fi
    say "[prep] reusing the baseline worktree"
else
    mkdir -p "${BASELINE_WT:h}" 2>/dev/null
    if ! git -C "${GIT_REPO}" worktree add --quiet --detach "${BASELINE_WT}" "${BASELINE_SHA}" >"${WORK}/worktree.log" 2>&1; then
        cat "${WORK}/worktree.log" >&2
        print -r -- "[identity] cannot create the baseline git worktree at ${BASELINE_WT}" >&2
        exit 3
    fi
    say "[prep] created the baseline worktree"
fi
unset _wt_common _repo_common

[[ -d "${CURRENT_TREE}" ]] || die "--current ${CURRENT_TREE} is not a directory"
CURRENT_TREE="${CURRENT_TREE:A}"
VENV_DIR=""
[[ -x "${HARNESS_REPO}/.venv/bin/python3" ]] && VENV_DIR="${HARNESS_REPO}/.venv"
if [[ -n "${VENV_DIR}" ]]; then
    PY_BIN="${VENV_DIR}/bin"
else
    PY_BIN="$(command -v python3)"; PY_BIN="${PY_BIN:h}"
fi
[[ -n "${PY_BIN}" && -x "${PY_BIN}/python3" ]] || die "python3 not found (needed by the generators and the notebook render)"

say "[prep] snapshot baseline -> ${WORK}/snap/baseline"
snapshot_tree "${BASELINE_WT}" "${WORK}/snap/baseline" || die "baseline snapshot failed"
say "[prep] snapshot current ${CURRENT_TREE} -> ${WORK}/snap/current"
snapshot_tree "${CURRENT_TREE}" "${WORK}/snap/current" || die "current snapshot failed"

# -----------------------------------------------------------------------------
# Fake cluster CLIs and helper scripts
# -----------------------------------------------------------------------------
SHIM="${WORK}/shim"
HELPERS="${WORK}/helpers"
FIXTURES="${WORK}/fixtures"
mkdir -p "${SHIM}" "${HELPERS}" "${FIXTURES}"
for _c in "${FAKE_COMMANDS[@]}"; do
    cat > "${SHIM}/${_c}" <<EOF
#!/bin/sh
# identity harness: fake ${_c}. Logs its argv and refuses, so nothing reaches a cluster.
{ printf '%s' '${_c}'; for _a in "\$@"; do printf ' [%s]' "\$_a"; done; printf '\n'; } >> "\${SHIM_LOG:-/dev/null}"
echo "identity-harness: fake ${_c} - no cluster here" >&2
exit 97
EOF
    chmod +x "${SHIM}/${_c}"
done
unset _c

# The fixed toggle snippet (contract 7.3), scripts value: the only text the
# generators and the j2 may add in scripts mode (see ALLOW_DELTA).
DEPLOY_MODE_SNIPPET='# ---- Deploy mode ---------------------------------------------------------------
# scripts  = the repo renders and applies raw manifests (StatefulSet broker, Deployments, ...).
# operator = Confluent for Kubernetes (CFK) and cp-fko, installed through OLM, run the platform.
# Unset or any other value means operator; a scripts-mode install in the namespace then stops every script.
export CONFLUENT_DEPLOY_MODE="scripts"
'
print -rn -- "${DEPLOY_MODE_SNIPPET}" > "${HELPERS}/deploy_mode_snippet.txt"

# The j2 template rendered alone with WP-B's fixed context, as
# tests/test_confluent_operator_generators.py does: _comment dropped,
# keep_trailing_newline, KEY=VALUE arguments added to the context. The context
# file comes from the harness checkout, so both sides render the same input.
J2_CONTEXT="${HARNESS_REPO}/tests/fixtures/confluent_j2_context.json"
[[ -f "${J2_CONTEXT}" ]] || die "missing ${J2_CONTEXT} (WP-B's j2 context fixture)"
cp "${J2_CONTEXT}" "${HELPERS}/confluent_j2_context.json"
cat > "${HELPERS}/render_j2.py" <<'PY'
import json
import sys

import jinja2

sys.dont_write_bytecode = True
with open(sys.argv[1]) as fh:
    ctx = json.load(fh)
ctx.pop("_comment", None)
for arg in sys.argv[2:]:
    key, _, value = arg.partition("=")
    ctx[key] = value
with open("src/helpers/config_file_jinja2_templates/confluent_variable_template.sh.j2") as fh:
    text = fh.read()
sys.stdout.write(jinja2.Environment(keep_trailing_newline=True).from_string(text).render(**ctx))
PY

# Removes the allowed scripts-mode deltas of one probe (ALLOW_DELTA) from the
# tree under test's report:   allow.pl SNIPPET_FILE ALLOWANCES REPORT > FILTERED
# Each allowance removes its fixed text at most once, and only in its own place.
cat > "${HELPERS}/allow.pl" <<'PL'
use strict;
use warnings;
my ($snip_file, $allow, $report) = @ARGV;
sub slurp { my ($f) = @_; open my $fh, '<', $f or die "$f: $!"; local $/; my $c = <$fh>; return defined $c ? $c : ''; }
my $snip = slurp($snip_file);
my $r = slurp($report);
my %want = map { $_ => 1 } split /,/, $allow;
# stdout = between "### stdout" and "### stderr"; the rest holds the written files
my ($head, $out, $rest) = $r =~ /\A(.*?^### stdout\n)(.*?)(^### stderr\n.*)\z/ms or die "allow.pl: no stdout section\n";
if ($want{'j2-snippet'}) {
    my $anchor = "# Topology from https://github.com/confluentinc/cp-all-in-one (KRaft variant).\n";
    $out =~ s/^\Q$anchor$snip\E/$anchor/m;
}
if ($want{'info-line'}) {
    $out =~ s/^\[INFO\] CONFLUENT_DEPLOY_MODE="scripts" written to confluent_vars\.sh\.\n//m;
}
if ($want{'dryrun-line'}) {
    $out =~ s/^\[INFO\] --dry-run: would write CONFLUENT_DEPLOY_MODE="scripts" to (?:confluent_vars\.sh|tmp\.XXXXXX)\.\n//m;
}
# help-confluent / help-flink: the generators' --help gains exactly these option
# lines (the new flags), once, directly after the "-h, --help" line + blank line.
my $help_anchor = "  -h, --help                this message\n\n";
my %help_block = (
    'help-confluent' => <<'HELP_CONFLUENT',
Deploy mode:
  --deploy-mode MODE        scripts | operator (CONFLUENT_DEPLOY_MODE). New file:
                            operator. Existing file: keeps its value.
  --switch-deploy-mode      allow --deploy-mode to change an existing file's mode
                            (a fresh install: scripts -> operator needs
                            x.8_confluent_wipe_scripts_mode.sh first)

Operator mode only (ignored with a warning in scripts mode):
  --sasl-impl IMPL          plain (default, native CFK) | scram (configOverrides,
                            outside Confluent Support)
  --tls-source SRC          repo (default, repo-made certificates) | cfk
  --approval MODE           Manual (default) | Automatic InstallPlan approval
  --kraft-replicas N        CONFLUENT_KRAFT_REPLICAS (odd, >= 1)
  --kraft-storage SIZE      CONFLUENT_KRAFT_STORAGE_SIZE (e.g. 20Gi)

HELP_CONFLUENT
    'help-flink' => <<'HELP_FLINK',
Flink operator mode:
  --operator-source SRC     helm | olm | existing (FLINK_OPERATOR_SOURCE). Without
                            it the Flink scripts follow the platform mode: olm when
                            CONFLUENT_DEPLOY_MODE is operator (or missing), else helm.
  --cmf-resource-mode MODE  cli | cfk (FLINK_CMF_RESOURCE_MODE). Without it: cfk
                            when the operator source is not helm, else cli.

HELP_FLINK
);
for my $h ('help-confluent', 'help-flink') {
    next unless $want{$h};
    my $block = $help_block{$h};
    $out =~ s/^\Q$help_anchor$block\E/$help_anchor/m;
}
# confluent_vars.sh, and the .bak the sizing splice takes of it after the toggle write
for my $file ('confluent_vars.sh', 'confluent_vars.sh.bak') {
    last unless $want{'file-snippet'};
    pos($rest) = 0;
    next unless $rest =~ m{^--- (?:new|mod) repo/configs/confluent_platform_config/\Q$file\E\n}mg;
    # only inside that file's content (up to the next "--- " entry)
    my $start = pos($rest);
    my $end = $rest =~ /^--- (?:new|mod|del) /mg ? $-[0] : length($rest);
    my $body = substr($rest, $start, $end - $start);
    $body =~ s/\n\n\Q$snip\E/\n/;
    substr($rest, $start, $end - $start) = $body;
}
print $head, $out, $rest;
PL

# Runs the vars-generation notebook headless (marimo App.run) with the Generate
# button pressed and optional widget overrides (name=true|false|text), then
# prints the notebook's own rendering of confluent_variable_template.sh.j2.
cat > "${HELPERS}/render_notebook.py" <<'PY'
import os
import sys
from types import SimpleNamespace

sys.dont_write_bytecode = True
sys.path.insert(0, os.getcwd())
import src.helpers.vars_handling_helpers as _vh  # noqa: E402

# The only random input: the KRaft cluster id the notebook proposes.
_vh.generate_cluster_id = lambda *a, **k: "IdentityHarnessCID0001"
import confluent_platform_vars_generation as nb  # noqa: E402

class Widget(SimpleNamespace):
    """Stand-in for an overridden widget: .value, and .style() so layout cells still run."""

    def style(self, *args, **kwargs):
        return self


overrides = {"run_button": Widget(value=True)}
for arg in sys.argv[1:]:
    key, _, value = arg.partition("=")
    overrides[key] = Widget(value={"true": True, "false": False}.get(value, value))
_, defs = nb.app.run(defs=overrides)
sys.stdout.write(defs["rendered_variables_file_confluent"])
PY

# One sandboxed probe run in a single process (process starts are the expensive
# part here, so prepare, run, report and restore all happen in this one script):
#   sandbox.pl list SANDBOX OUT ROOT...       listing of ROOTs (relative to SANDBOX)
#   sandbox.pl probe SANDBOX SNAPSHOT WORK VENV TIMEOUT NAME COMMAND OUTPREFIX KEEP
#                    [FIXTURE_SRC=>DEST ...] -- [ENV=VALUE ...]
# probe: fresh HOME/TMPDIR/MCM state/configs, fixtures copied in, COMMAND run
# with `zsh -c` under exactly the given environment (own process group, killed
# after TIMEOUT s), then OUTPREFIX.report (normalised) and OUTPREFIX.rc are
# written, everything the probe changed in the repo clone outside configs/ is put
# back from SNAPSHOT, and the clone is checked against its .pristine listing
# (removed when it no longer matches, so the next probe re-clones).
cat > "${HELPERS}/sandbox.pl" <<'PL'
use strict;
use warnings;
use File::Find;
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Time::HiRes qw(lstat stat utime);

sub listing {
    my ($sb, @roots) = @_;
    my %h;
    for my $r (@roots) {
        my $abs = "$sb/$r";
        next unless -e $abs || -l $abs;
        find({ no_chdir => 1, wanted => sub {
            my $p = $File::Find::name;
            my $rel = substr($p, length($sb) + 1);
            my @s = lstat($p) or return;
            if (-d $p && !-l $p) {
                if ($rel =~ m{(^|/)__pycache__$} || $rel eq 'home/.cache/marimo/logs') { $File::Find::prune = 1; return; }
                $h{$rel} = "d\t-\t-";
            } else {
                $h{$rel} = sprintf("f\t%.6f\t%d", $s[9], $s[7]);
            }
        } }, $abs);
    }
    return \%h;
}
sub dump_listing { my ($h) = @_; return join('', map { "$h->{$_}\t$_\n" } sort keys %$h); }
sub slurp { my ($f) = @_; open my $fh, '<', $f or return ''; local $/; my $c = <$fh>; return defined $c ? $c : ''; }
sub spew { my ($f, $c) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $c; close $fh or die "$f: $!"; }

sub copy_like {   # restores SRC at DEST: content, mode, mtime (a symlink as a symlink)
    my ($src, $dest) = @_;
    make_path(dirname($dest));
    unlink $dest;
    if (-l $src) { symlink(readlink($src), $dest) or die "symlink $dest: $!"; return; }
    copy($src, $dest) or die "copy $src -> $dest: $!";
    my @s = stat($src);
    chmod($s[2] & 07777, $dest);
    utime($s[8], $s[9], $dest);
}

my $cmd = shift @ARGV;
if ($cmd eq 'list') {
    my ($sb, $out, @roots) = @ARGV;
    spew($out, dump_listing(listing($sb, @roots)));
    exit 0;
}
die "sandbox.pl: unknown command '$cmd'\n" unless $cmd eq 'probe';

my ($sb, $snap, $work, $venv, $timeout, $name, $command, $outp, $keep) = splice(@ARGV, 0, 9);
my (@fixtures, @env);
my $seen_sep = 0;
for (@ARGV) { if ($_ eq '--') { $seen_sep = 1; next; } if ($seen_sep) { push @env, $_; } else { push @fixtures, $_; } }

# --- prepare -----------------------------------------------------------------
remove_tree("$sb/home", "$sb/tmp", "$sb/mcm", "$sb/repo/configs");
unlink map { "$sb/$_" } qw(calls.log stdout stderr rc);
make_path("$sb/home", "$sb/tmp", "$sb/mcm", "$sb/repo/configs/confluent_platform_config");
for my $f (@fixtures) {
    my ($src, $dest) = split /=>/, $f, 2;
    make_path(dirname("$sb/repo/$dest"));
    copy($src, "$sb/repo/$dest") or die "fixture $src: $!";
}
my $before = listing($sb, qw(repo home mcm));

# --- run -----------------------------------------------------------------------
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    setpgrp(0, 0);
    %ENV = ();
    for my $kv (@env) { my ($k, $v) = split /=/, $kv, 2; $ENV{$k} = $v; }
    chdir("$sb/repo") or die "chdir: $!";
    open STDIN, '<', '/dev/null';
    open STDOUT, '>', "$sb/stdout" or die;
    open STDERR, '>', "$sb/stderr" or die;
    exec('/bin/zsh', '-c', $command) or exit 127;
}
my $rc;
eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm $timeout;
    waitpid($pid, 0);
    alarm 0;
    $rc = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
};
if ($@) {
    kill 'KILL', -$pid;
    waitpid($pid, 0);
    open my $e, '>>', "$sb/stderr"; print $e "identity-harness: probe timed out after ${timeout}s\n"; close $e;
    $rc = 124;
}

# --- report ------------------------------------------------------------------
my $after = listing($sb, qw(repo home mcm));
my @changes;
for my $p (sort(keys %$after), sort(keys %$before)) {
    my ($ta) = split /\t/, ($after->{$p} // '');
    my ($tb) = split /\t/, ($before->{$p} // '');
    if (!exists $before->{$p}) { push @changes, ['new', $ta, $p]; }
    elsif (!exists $after->{$p}) { push @changes, ['del', $tb, $p]; }
    elsif ($ta eq 'f' && $after->{$p} ne $before->{$p}) { push @changes, ['mod', $ta, $p]; }
}
my %u; @changes = sort { $a->[2] cmp $b->[2] } grep { !$u{"$_->[0] $_->[2]"}++ } @changes;

my $r = "### probe: $name\n### command: $command\n### exit: $rc\n### stdout\n" . slurp("$sb/stdout")
      . "### stderr\n" . slurp("$sb/stderr") . "### fake cluster CLI calls\n";
my $calls = slurp("$sb/calls.log");
$r .= length($calls) ? $calls : "(none)\n";
$r .= "### files written or removed (configs/: with content; elsewhere: names only)\n";
for my $c (@changes) {
    my ($kind, $type, $p) = @$c;
    next unless $type eq 'f';
    $r .= "--- $kind $p\n";
    $r .= slurp("$sb/$p") if $kind ne 'del' && $p =~ m{^repo/configs/};
}
# Paths, mktemp names, timestamps and durations that differ run to run.
my @subst;
for my $pair (["$sb/repo", '<REPO>'], [$sb, '<SANDBOX>'], ["$work/helpers", '<HELPERS>'],
              ["$work/shim", '<SHIM>'], [$work, '<WORK>'], [$venv, '<VENV>']) {
    my ($path, $tag) = @$pair;
    push @subst, [$path, $tag];
    (my $alt = $path) =~ s{^/private/}{/};
    push @subst, [$alt, $tag] if $alt ne $path;
}
for my $s (@subst) { my ($p, $t) = @$s; $r =~ s/\Q$p\E/$t/g; }
$r =~ s{\btmp\.[A-Za-z0-9]{6,}}{tmp.XXXXXX}g;
$r =~ s{\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?}{<TIMESTAMP>}g;
$r =~ s{\b\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\b}{<TIMESTAMP>}g;
$r =~ s{(\[TIMER\] \S+ completed in )(?:\d+m )?\d+s}{$1<T>}g;
spew("$outp.report", $r);
spew("$outp.rc", "$rc\n");
if ($keep) {
    make_path("$outp.raw");
    for my $f (qw(stdout stderr calls.log)) { copy("$sb/$f", "$outp.raw/$f") if -e "$sb/$f"; }
    spew("$outp.raw/changes", join('', map { join("\t", @$_) . "\n" } @changes));
    if (-d "$sb/repo/configs") {
        find({ no_chdir => 1, wanted => sub { return unless -f $_;
            my $rel = substr($_, length("$sb/repo") + 1); copy_like($_, "$outp.raw/$rel"); } }, "$sb/repo/configs");
    }
}

# --- restore -----------------------------------------------------------------
for my $c (@changes) {
    my ($kind, $type, $p) = @$c;
    next unless $p =~ m{^repo/} && $p !~ m{^repo/configs(/|$)};
    (my $rel = $p) =~ s{^repo/}{};
    if ($type eq 'd') {
        if ($kind eq 'new') { remove_tree("$sb/$p"); } elsif ($kind eq 'del') { make_path("$sb/$p"); }
        next;
    }
    if (-e "$snap/$rel" || -l "$snap/$rel") { copy_like("$snap/$rel", "$sb/$p"); } else { unlink "$sb/$p"; }
}
remove_tree("$sb/repo/configs");
unlink "$sb/.pristine" if slurp("$sb/.pristine") ne dump_listing(listing($sb, 'repo'));
exit 0;
PL

# -----------------------------------------------------------------------------
# Fixtures: name -> "source=>path under the repo clone". Every fixture is a
# file made once here, identical for both sides. 'full' and 'iceberg' come
# from the BASELINE tree (its generators and its iceberg example).
# -----------------------------------------------------------------------------
typeset -A FIXTURE=(
    minimal "${FIXTURES}/minimal_confluent_vars.sh=>configs/confluent_platform_config/confluent_vars.sh"
    cpd     "${FIXTURES}/cpd_vars.sh=>configs/cp4d_config/cpd_vars.sh"
    full    "${FIXTURES}/full_confluent_vars.sh=>configs/confluent_platform_config/confluent_vars.sh"
    full-scripts  "${FIXTURES}/full_scripts_confluent_vars.sh=>configs/confluent_platform_config/confluent_vars.sh"
    full-unquoted "${FIXTURES}/full_unquoted_confluent_vars.sh=>configs/confluent_platform_config/confluent_vars.sh"
    iceberg "${FIXTURES}/iceberg_watsonx_setup.sh=>configs/confluent_platform_config/iceberg_watsonx_setup.sh"
)
for _i in {1..${TOTAL}}; do
    for _f in ${(s:+:)PFIX[_i]}; do
        [[ "${_f}" == none || -n "${FIXTURE[${_f}]:-}" ]] || die "probe '${PNAME[_i]}': unknown fixture '${_f}'"
    done
done
unset _i _f
cat > "${FIXTURES}/minimal_confluent_vars.sh" <<'EOF'
#!/bin/zsh
# identity harness: minimal Confluent config (no Flink settings)
export OCP_URL="https://api.identity-harness.invalid:6443"
export OC_LOGIN="true"
export PROJECT_CONFLUENT_SERVER="confluent"
export CONFLUENT_VERSION="8.2.0"
export CONFLUENT_C3_VERSION="2.5.0"
EOF
cat > "${FIXTURES}/cpd_vars.sh" <<'EOF'
#!/bin/zsh
# identity harness: values the Confluent generator seeds from (never sourced by it)
export OCP_URL="https://api.identity-harness.invalid:6443"
export OCP_USERNAME="identity-admin"
export OCP_PASSWORD="identity-password"
export STG_CLASS_BLOCK="identity-block"
export STG_CLASS_FILE="identity-file"
EOF
cp "${WORK}/snap/baseline/${P}/connector_configs/iceberg-watsonx.example.sh" "${FIXTURES}/iceberg_watsonx_setup.sh" \
    || die "missing ${P}/connector_configs/iceberg-watsonx.example.sh in the baseline"

# -----------------------------------------------------------------------------
# Sandboxed runs: one reusable repo clone per worker and side
# -----------------------------------------------------------------------------
# A probe gets a fresh HOME, TMPDIR, MCM state and configs/ every time; what it
# writes elsewhere in the clone is put back from the snapshot (sandbox.pl).
# Reusing clones keeps the run fast: cloning ~800 files per probe serialises on
# the filesystem.

# The probe environment (env -i style: nothing else from this shell leaks in).
probe_env() {   # SIDE SANDBOX -> reply
    local side="$1" sb="$2"
    reply=(
        HOME="${sb}/home" TMPDIR="${sb}/tmp/" USER="${USER:-identity}" LOGNAME="${LOGNAME:-identity}"
        PATH="${SHIM}:${PY_BIN}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        SHELL=/bin/zsh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=dumb NO_COLOR=1 TZ=UTC
        SHIM_LOG="${sb}/calls.log" MCM_STATE_FILE="${sb}/mcm/multi_cluster_management.sh"
        _CP4D_PREP_DONE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONHASHSEED=0
        P="${P}" PU="${PU}" PF="${PF}" PFU="${PFU}" CID="${CID}" IDENTITY_HELPERS="${HELPERS}"
        IDENTITY_SIDE="${side}"
    )
    # The rule under test: the tree under test runs with the mode set explicitly.
    # The generators and the notebook default to operator and ignore the environment,
    # so they get the explicit scripts selection as arguments (empty on the baseline).
    if [[ "${side}" == current ]]; then
        reply+=(CONFLUENT_DEPLOY_MODE=scripts
            "IDENTITY_GEN_ARGS=--deploy-mode scripts"
            "IDENTITY_NB_ARGS=deploy_mode_select=scripts"
            "IDENTITY_J2_ARGS=confluent_deploy_mode=scripts flink_operator_source=helm")
    else
        reply+=(IDENTITY_GEN_ARGS= IDENTITY_NB_ARGS= IDENTITY_J2_ARGS=)
    fi
    return 0
}

# sandbox_run SIDE SANDBOX NAME FIXTURES COMMAND OUTPREFIX
sandbox_run() {
    local side="$1" sb="$2" name="$3" fixtures="$4" command="$5" outp="$6" f
    local -a fx=() reply
    mkdir -p "${sb}"
    if [[ ! -f "${sb}/.pristine" ]]; then
        rm -rf "${sb}/repo"
        clone_tree "${WORK}/snap/${side}" "${sb}/repo" || return 1
        /usr/bin/perl "${HELPERS}/sandbox.pl" list "${sb}" "${sb}/.pristine" repo || return 1
    fi
    for f in ${(s:+:)fixtures}; do [[ "${f}" == none ]] || fx+=("${FIXTURE[${f}]}"); done
    probe_env "${side}" "${sb}"
    /usr/bin/perl "${HELPERS}/sandbox.pl" probe "${sb}" "${WORK}/snap/${side}" "${WORK}" "${VENV_DIR:-/nonexistent-venv}" \
        "${PROBE_TIMEOUT}" "${name}" "${command}" "${outp}" "$(${KEEP} && print 1 || print 0)" "${fx[@]}" -- "${reply[@]}"
}

# One probe, both sides at once on worker W -> run/IDX/{result,diff,seconds}.
run_probe() {   # IDX WORKER
    local i="$1" w="$2" d="${WORK}/run/${1}" res brc
    typeset -F t=${EPOCHREALTIME}
    mkdir -p "${d}"
    sandbox_run baseline "${WORK}/pool/${w}/baseline" "${PNAME[i]}" "${PFIX[i]}" "${PCMD[i]}" "${d}/baseline" &
    sandbox_run current "${WORK}/pool/${w}/current" "${PNAME[i]}" "${PFIX[i]}" "${PCMD[i]}" "${d}/current" &
    wait
    local allow="${ALLOW_DELTA[${PNAME[i]}]:-}" cmp="${d}/current.report" label="current:${PNAME[i]}"
    if [[ -f "${d}/baseline.report" && -f "${d}/current.report" \
          && "$(<"${d}/baseline.report")" == "$(<"${d}/current.report")" ]]; then
        res=IDENTICAL
    else
        res=DIFFERENT
        # Only the fixed toggle texts this probe is allowed may go; whatever else differs fails.
        if [[ -n "${allow}" && -f "${d}/current.report" ]] \
            && /usr/bin/perl "${HELPERS}/allow.pl" "${HELPERS}/deploy_mode_snippet.txt" "${allow}" \
                "${d}/current.report" > "${d}/current.allowed" 2>"${d}/allow.err"; then
            cmp="${d}/current.allowed" label="current:${PNAME[i]} (allowed delta removed: ${allow})"
            [[ -f "${d}/baseline.report" && "$(<"${d}/baseline.report")" == "$(<"${cmp}")" ]] && res=ALLOWED
        fi
        [[ "${res}" == ALLOWED ]] || diff -u --label "baseline:${PNAME[i]}" --label "${label}" \
            "${d}/baseline.report" "${cmp}" > "${d}/diff"
    fi
    # The probe must still exercise what it was written for (its baseline exit code).
    brc="$(<"${d}/baseline.rc" 2>/dev/null)"
    if [[ "${PEXIT[i]}" != '*' && "${brc}" != "${PEXIT[i]}" ]]; then
        res=BROKEN
        print -r -- "baseline exit ${brc:-?} != expected ${PEXIT[i]}" > "${d}/broken"
    fi
    printf '%.1f\n' $(( EPOCHREALTIME - t )) > "${d}/seconds"
    print -r -- "${res}" > "${d}/result.tmp"
    mv "${d}/result.tmp" "${d}/result"
}

# -----------------------------------------------------------------------------
# The 'full' fixture: the BASELINE generators' output plus a no-op login
# -----------------------------------------------------------------------------
say "[prep] building the 'full' fixture with the baseline generators"
sandbox_run baseline "${WORK}/fixture-build" fixture-build cpd \
    "${P}/0_confluent_prepare_template_config.sh --size small --cluster-id ${CID} && ${PF}/0_flink_prepare_template_config.sh --size small && cat configs/confluent_platform_config/confluent_vars.sh > ${FIXTURES}/generated_confluent_vars.sh" \
    "${WORK}/fixture-build/out" || die "fixture sandbox failed"
if [[ "$(<"${WORK}/fixture-build/out.rc")" != 0 || "$(<"${WORK}/fixture-build/out.report")" != *$'### fake cluster CLI calls\n(none)\n'* ]]; then
    cat "${WORK}/fixture-build/out.report" >&2
    die "the baseline generators failed to build the 'full' fixture"
fi
{
    print -r -- "$(<"${FIXTURES}/generated_confluent_vars.sh")"
    cat <<'EOF'

# ---- identity harness overrides ----------------------------------------------
# A login that succeeds without a cluster: source_env_setup.sh wraps it as
# "oc whoami || true", so each script runs on to its first (fake) cluster call.
export OCP_URL="https://api.identity-harness.invalid:6443"
export OC_LOGIN="true"
EOF
} > "${FIXTURES}/full_confluent_vars.sh"
# 'full' + the generators' toggle snippet (what 0_ --deploy-mode scripts appends), and
# 'full' + a bare unquoted line: both name scripts mode in the file itself.
{ print -r -- "$(<"${FIXTURES}/full_confluent_vars.sh")"; print; print -rn -- "${DEPLOY_MODE_SNIPPET}"; } \
    > "${FIXTURES}/full_scripts_confluent_vars.sh"
{ print -r -- "$(<"${FIXTURES}/full_confluent_vars.sh")"; print -r -- "export CONFLUENT_DEPLOY_MODE=scripts"; } \
    > "${FIXTURES}/full_unquoted_confluent_vars.sh"
rm -rf "${WORK}/fixture-build"
say "[prep] done in $(elapsed)"

# -----------------------------------------------------------------------------
# Run the probes on JOBS workers; report [n/total] as each one finishes.
# -----------------------------------------------------------------------------
say "running ${TOTAL} probes on ${JOBS} workers: baseline vs current (CONFLUENT_DEPLOY_MODE=scripts)"
typeset -i next=1 finished=0 nbad=0 nallowed=0 _w _p
typeset -a busy failed
for _w in {1..${JOBS}}; do busy[_w]=0; done
while (( finished < TOTAL )); do
    for _w in {1..${JOBS}}; do
        if (( busy[_w] == 0 && next <= TOTAL )); then
            busy[_w]=${next}
            run_probe ${next} ${_w} &
            (( next++ ))
        fi
    done
    for _w in {1..${JOBS}}; do
        _p=${busy[_w]}
        (( _p > 0 )) && [[ -f "${WORK}/run/${_p}/result" ]] || continue
        busy[_w]=0
        (( finished++ ))
        _res="$(<"${WORK}/run/${_p}/result")"
        [[ "${_res}" == (IDENTICAL|ALLOWED) ]] || { (( nbad++ )); failed+=(${_p}); }
        [[ "${_res}" == ALLOWED ]] && (( nallowed++ ))
        printf '[identity] [%d/%d] %3d%% %-42s %-9s (%ss)\n' ${finished} ${TOTAL} $(( finished * 100 / TOTAL )) \
            "${PNAME[_p]}" "${_res}" "$(<"${WORK}/run/${_p}/seconds")"
    done
    (( finished < TOTAL )) && zselect -t 5
done
wait

say "------------------------------------------------------------------------------"
if (( nbad == 0 )); then
    say "IDENTICAL: ${TOTAL}/${TOTAL} probes match baseline ${BASELINE_REF}, ${nallowed} of them only after removing their allowed toggle text ($(elapsed))"
    ${KEEP} && say "outputs kept in ${WORK}"
    exit 0
fi
for _p in ${(on)failed}; do
    say "probe ${PNAME[_p]}: $(<"${WORK}/run/${_p}/result") (${WORK}/run/${_p})"
    [[ -f "${WORK}/run/${_p}/broken" ]] && say "  $(<"${WORK}/run/${_p}/broken") - the probe no longer tests what it was written for"
    [[ -f "${WORK}/run/${_p}/diff" ]] && print -r -- "$(<"${WORK}/run/${_p}/diff")"
done
say "NOT IDENTICAL: ${nbad}/${TOTAL} probes differ from baseline ${BASELINE_REF} or are broken ($(elapsed))"
say "outputs kept in ${WORK}"
KEEP=true
exit 1
