#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - install a connector plugin into Kafka Connect
# ------------------------------------------------------------------------------
# Takes a connector from a URL, a local file, or a Confluent Hub coordinate and
# installs it into the running Connect worker.
#
# WHY A PVC AND NOT A DERIVED IMAGE
# The stock Connect images bundle no connectors at all - cp-server-connect and
# cp-server-connect-base are identical, and both ship only confluent-hub-client
# (the -base names are deprecated in CP 8.3.0, removed in 8.4.0). The supported
# way to add plugins is to bake them into an image at build time. That needs a
# registry and a build host with egress, which this stack does not assume, so
# this script keeps the equivalent state in a PVC mounted onto the existing
# deployment instead. The first run adds the volume; later runs reuse it.
#
# Plugins land in their own directory under the mount, which is appended to
# CONNECT_PLUGIN_PATH. Per the Connect user guide a plugin is "a directory on
# the file system that contains all required JAR files and third-party
# dependencies for the plugin" or "a single uber JAR" - both are handled here.
#
# RESTART IS REQUIRED. Workers discover plugins only at startup: "When you start
# your Connect workers, each worker discovers all connectors, transforms, and
# converter plugins found inside the directories on the plugin path." So this
# rolls the Connect deployment. Running connectors stop for the duration; their
# offsets live in Kafka topics, so they resume where they left off.
#
# Usage:
#   ./x.3_confluent_add_connector.sh <source> [<source>...] [options]
#   ./x.3_confluent_add_connector.sh --file connectors.txt [options]
#   ./x.3_confluent_add_connector.sh --list
#   ./x.3_confluent_add_connector.sh --remove <name>
#
# Several sources install in one run and share a SINGLE rollout: each is staged
# in turn, then Connect restarts once at the end. Sources are classified up
# front, so a typo in the last one is reported before anything is downloaded.
#
#   <source> is one of:
#     https://www.confluent.io/hub/owner/name   a Confluent Hub page URL; the
#                                 archive is resolved through the Hub API
#     https://.../connector.zip   a Hub-style ZIP archive, downloaded in-cluster
#     ./path/to/connector.zip     a local ZIP, streamed into the pod
#     ./path/to/connector.jar     a local uber JAR
#     ./path/to/plugin-dir/       a local directory of JARs
#     owner/name:version          a Confluent Hub coordinate (needs egress)
#
#   --file <p>    install every connector listed in a manifest file, the
#     (-f)        requirements.txt equivalent. One source per line, with
#                 optional per-line --name and --force after it:
#
#                   # comments and blank lines are ignored
#                   confluentinc/kafka-connect-jdbc:latest
#                   confluentinc/kafka-connect-http:latest  --name http-sink
#                   ./local/connector.zip                   --force
#
#                 A YAML list works too, so a .yaml manifest reads naturally:
#
#                   connectors:
#                     - confluentinc/kafka-connect-jdbc:latest
#                     - confluentinc/kafka-connect-http:latest --name http-sink
#
#                 Sources on the command line are installed as well as the
#                 file's. Run-wide flags (--keep-going, --no-restart, --dry-run)
#                 belong on the command line, not in the manifest.
#   --name <n>    directory name for the plugin (default: derived from source).
#                 Single source only - with several, use a per-line --name.
#   --list        list installed plugins and the worker's loaded connectors
#   --remove <n>  delete a plugin directory and restart
#   --no-restart  stage the files but skip the rollout (plugins stay invisible
#                 until the next restart)
#   --keep-going  with several sources, install the ones that work and report
#                 the failures, instead of stopping at the first (the default is
#                 to stop WITHOUT restarting, so nothing goes live half-done)
#   --force       overwrite an existing plugin directory of the same name
#   --yes         skip the confirmation prompt
#   --dry-run     report what would change, change nothing
# ==============================================================================

SOURCES=()
PLUGIN_NAME=""
DO_LIST=false
REMOVE_NAME=""
NO_RESTART=false
FORCE=false
ASSUME_YES=true
DRY_RUN=false
KEEP_GOING=false

MANIFEST=""

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --file|-f)    _need_value "$1" "${2:-}"; MANIFEST="$2"; shift 2 ;;
        --name)       _need_value "$1" "${2:-}"; PLUGIN_NAME="$2"; shift 2 ;;
        --list)       DO_LIST=true; shift ;;
        --remove)     _need_value "$1" "${2:-}"; REMOVE_NAME="$2"; shift 2 ;;
        --no-restart) NO_RESTART=true; shift ;;
        --keep-going) KEEP_GOING=true; shift ;;
        --force)      FORCE=true; shift ;;
        --yes|-y)     ASSUME_YES=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    sed -n '16,88p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
        *)  SOURCES+=("$1"); shift ;;
    esac
done

# ------------------------------------------------------------------------------
# --file: a requirements.txt-style manifest
# ------------------------------------------------------------------------------
# One source per line, with optional per-line flags after it:
#
#   # comments and blank lines are ignored
#   confluentinc/kafka-connect-jdbc:latest
#   confluentinc/kafka-connect-http:latest   --name http-sink
#   ./local/connector.zip                    --force
#
# Also accepts a YAML list, so a .yaml manifest reads naturally:
#
#   connectors:
#     - confluentinc/kafka-connect-jdbc:latest
#     - confluentinc/kafka-connect-http:latest --name http-sink
#
# Only per-source flags are honoured per line (--name, --force). Run-wide flags
# (--keep-going, --no-restart, --dry-run, --yes) stay on the command line, since
# they describe the run and not any one plugin.
#
# NOTE the line is split on whitespace, so a path containing spaces must be
# quoted the way a shell would expect.
MANIFEST_NAMES=()   # parallel to SOURCES: per-source --name, "" when unset
MANIFEST_FORCE=()   # parallel to SOURCES: "1" when that line passed --force

# Command-line sources have no per-line overrides.
for _ in "${SOURCES[@]}"; do MANIFEST_NAMES+=(""); MANIFEST_FORCE+=(""); done

if [[ -n "${MANIFEST}" ]] && { $DO_LIST || [[ -n "${REMOVE_NAME}" ]]; }; then
    echo "[ERROR] --file cannot be combined with --list or --remove." >&2; exit 1
fi

if [[ -n "${MANIFEST}" ]]; then
    [[ -f "${MANIFEST}" ]] || { echo "[ERROR] Manifest '${MANIFEST}' not found." >&2; exit 1; }

    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _lineno=$(( _lineno + 1 ))
        # Strip comments (# to end of line), CRs from Windows editors, and the
        # YAML list marker so a .yaml and a .txt manifest parse the same way.
        _line="${_line%%#*}"
        _line="${_line//$'\r'/}"
        # Trim with (z) word-splitting rather than an extendedglob pattern: the
        # ##[[:space:]]## form needs setopt extendedglob, which this script does
        # not set, so it silently trimmed nothing and a YAML '- item' arrived
        # with the dash still attached.
        _line="$(printf '%s' "${_line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "${_line}" ]] && continue
        # A bare 'connectors:' style key is a YAML container, not an entry.
        [[ "${_line}" == *: && "${_line}" != *[[:blank:]]* ]] && continue
        # YAML list item: '- source ...'
        if [[ "${_line}" == "-"[[:blank:]]* ]]; then
            _line="${_line#-}"
            _line="$(printf '%s' "${_line}" | sed 's/^[[:space:]]*//')"
        fi
        [[ -z "${_line}" ]] && continue

        # Split the line the way a shell would, so quoted paths survive.
        _parts=("${(z)_line}")
        _src="${_parts[1]}"
        # Strip surrounding quotes left by (z) splitting.
        _src="${_src#[\"\']}"; _src="${_src%[\"\']}"
        [[ -n "${_src}" ]] || continue

        _lname=""; _lforce=""
        _j=2
        while (( _j <= ${#_parts[@]} )); do
            case "${_parts[$_j]}" in
                --name)
                    _j=$(( _j + 1 ))
                    (( _j <= ${#_parts[@]} )) || {
                        echo "[ERROR] ${MANIFEST}:${_lineno}: --name needs a value." >&2; exit 1; }
                    _lname="${_parts[$_j]}"
                    _lname="${_lname#[\"\']}"; _lname="${_lname%[\"\']}" ;;
                --force) _lforce="1" ;;
                # Run-wide flags in a manifest would silently apply to the whole
                # run from one line, which is not what the line seems to say.
                --keep-going|--no-restart|--dry-run|--yes|-y|--list|--remove|--file|-f)
                    echo "[ERROR] ${MANIFEST}:${_lineno}: '${_parts[$_j]}' is a run-wide flag;" >&2
                    echo "[ERROR] pass it on the command line instead of in the manifest." >&2
                    exit 1 ;;
                *)
                    echo "[ERROR] ${MANIFEST}:${_lineno}: unexpected '${_parts[$_j]}'." >&2
                    echo "[ERROR] A line is: <source> [--name <n>] [--force]" >&2
                    exit 1 ;;
            esac
            _j=$(( _j + 1 ))
        done

        SOURCES+=("${_src}")
        MANIFEST_NAMES+=("${_lname}")
        MANIFEST_FORCE+=("${_lforce}")
    done < "${MANIFEST}"

    (( ${#SOURCES[@]} > 0 )) || {
        echo "[ERROR] Manifest '${MANIFEST}' lists no connectors." >&2; exit 1; }
    echo "[INFO] Read ${#SOURCES[@]} connector(s) from ${MANIFEST}."
fi

# --name renames the plugin directory, so it is meaningless for more than one
# source: every plugin would be given the same directory and overwrite the last.
# Per-line --name inside a manifest is fine, because it names only that line.
if [[ -n "${PLUGIN_NAME}" ]] && (( ${#SOURCES[@]} > 1 )); then
    echo "[ERROR] --name takes a single source (got ${#SOURCES[@]}). Use a per-line --name" >&2
    echo "[ERROR] in a --file manifest, or install them one at a time." >&2
    exit 1
fi

if $DO_LIST && { (( ${#SOURCES[@]} > 0 )) || [[ -n "${REMOVE_NAME}" ]]; }; then
    echo "[ERROR] --list takes no source and cannot be combined with --remove." >&2; exit 1
fi
if [[ -n "${REMOVE_NAME}" ]] && (( ${#SOURCES[@]} > 0 )); then
    echo "[ERROR] --remove cannot be combined with a source." >&2; exit 1
fi
if ! $DO_LIST && [[ -z "${REMOVE_NAME}" ]] && (( ${#SOURCES[@]} == 0 )); then
    echo "[ERROR] No source given. Try --help." >&2; exit 1
fi

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_CONNECT_PORT:=8083}"
: "${CONFLUENT_CONNECT_PLUGIN_PVC:=connect-plugins}"
: "${CONFLUENT_CONNECT_PLUGIN_SIZE:=2Gi}"
: "${CONFLUENT_ROLLOUT_TIMEOUT:=600s}"
: "${CONFLUENT_STORAGE_CLASS:=}"

# Mounted dir, and the path appended to CONNECT_PLUGIN_PATH. Kept off
# /usr/share/confluent-hub-components so a mount never masks image content.
PLUGIN_DIR="/opt/connect-plugins"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }
oc project "${NS}" >/dev/null
oc get deployment connect -n "${NS}" &>/dev/null || {
    echo "[ERROR] No 'connect' deployment in '${NS}'. Is CONFLUENT_INSTALL_CONNECT=true?" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
_connect_pod() {
    oc get pods -n "${NS}" -l app=connect --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Waits for a Running pod that is also Ready, so exec does not race the rollout.
_wait_pod() {
    local _p=""
    for _i in {1..60}; do
        _p="$(_connect_pod)"
        if [[ -n "${_p}" ]] && [[ "$(oc get pod "${_p}" -n "${NS}" \
              -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" == "true" ]]; then
            echo "${_p}"; return 0
        fi
        sleep 5
    done
    echo "[ERROR] No ready Connect pod after 5 minutes." >&2; return 1
}

# The Connect image ships no unzip(1). python3 is present, so use zipfile.
_unzip_in_pod() {
    local _pod="$1" _dir="$2" _zip="$3"
    oc exec "${_pod}" -n "${NS}" -- sh -c "
        if command -v unzip >/dev/null 2>&1; then
            cd '${_dir}' && unzip -q '${_zip}' && rm -f '${_zip}'
        else
            python3 -c \"import zipfile,sys,os
z=sys.argv[1]; d=sys.argv[2]
with zipfile.ZipFile(z) as f: f.extractall(d)
os.remove(z)\" '${_zip}' '${_dir}'
        fi
    "
}

_has_plugin_volume() {
    [[ "$(oc get deployment connect -n "${NS}" \
        -o jsonpath='{.spec.template.spec.volumes[?(@.name=="connect-plugins")].name}' 2>/dev/null)" == "connect-plugins" ]]
}

_plugin_path() {
    oc get deployment connect -n "${NS}" \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONNECT_PLUGIN_PATH")].value}' 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# --list
# ------------------------------------------------------------------------------
if $DO_LIST; then
    echo "=============================================================================="
    echo " Kafka Connect plugins - project '${NS}'"
    echo "=============================================================================="
    echo "  plugin path : $(_plugin_path)"
    echo "  plugin PVC  : $(_has_plugin_volume && echo "${CONFLUENT_CONNECT_PLUGIN_PVC} (mounted at ${PLUGIN_DIR})" || echo 'not attached')"
    echo ""
    POD="$(_connect_pod)"
    if [[ -z "${POD}" ]]; then
        echo "[WARN] No running Connect pod; cannot query the worker."
        exit 0
    fi
    if _has_plugin_volume; then
        echo "-- installed in ${PLUGIN_DIR} ------------------------------------------------"
        oc exec "${POD}" -n "${NS}" -- sh -c "ls -1 '${PLUGIN_DIR}' 2>/dev/null" || true
        echo ""
    fi
    echo "-- loaded by the worker ------------------------------------------------------"
    oc exec "${POD}" -n "${NS}" -- curl -sf "http://localhost:${CONFLUENT_CONNECT_PORT}/connector-plugins" 2>/dev/null \
        | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print("  (worker not answering)"); raise SystemExit(0)
for x in sorted(d, key=lambda i: i["class"]):
    print("  {:<70} {}".format(x["class"], x.get("type","")))
print("\n  {} plugin(s)".format(len(d)))' 2>/dev/null || echo "  (worker not answering)"
    exit 0
fi

# ------------------------------------------------------------------------------
# --remove
# ------------------------------------------------------------------------------
if [[ -n "${REMOVE_NAME}" ]]; then
    # Reject path traversal: this argument is interpolated into an rm -rf.
    case "${REMOVE_NAME}" in
        */*|..|.|"") echo "[ERROR] --remove takes a plain directory name." >&2; exit 1 ;;
    esac
    _has_plugin_volume || { echo "[ERROR] No plugin volume attached; nothing to remove." >&2; exit 1; }
    POD="$(_wait_pod)"
    oc exec "${POD}" -n "${NS}" -- sh -c "[ -e '${PLUGIN_DIR}/${REMOVE_NAME}' ]" 2>/dev/null || {
        echo "[ERROR] No plugin '${REMOVE_NAME}' in ${PLUGIN_DIR}. Use --list." >&2; exit 1; }

    echo "[INFO] Removing plugin '${REMOVE_NAME}' from ${PLUGIN_DIR}."
    if $DRY_RUN; then echo "[INFO] --dry-run: no changes made."; exit 0; fi
    if ! $ASSUME_YES; then
        printf "Remove '%s' and restart Connect? [y/N] " "${REMOVE_NAME}"
        read -r _r; case "${_r}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    fi
    oc exec "${POD}" -n "${NS}" -- rm -rf "${PLUGIN_DIR}/${REMOVE_NAME}"
    echo "[INFO] Removed. Restarting Connect..."
    oc rollout restart deployment/connect -n "${NS}"
    oc rollout status deployment/connect -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"
    echo "[INFO] Done. Run --list to confirm."
    exit 0
fi

# ------------------------------------------------------------------------------
# Classify the source
# ------------------------------------------------------------------------------
# Run once per source. Sets SOURCE, SRC_KIND, HUB_VERSION and PLUGIN_NAME for the
# source it is given; every later step reads those. Returns non-zero instead of
# exiting so --keep-going can skip one bad source and carry on.
_classify_source() {
SOURCE="$1"
SRC_KIND=""
# Start from the caller's --name (single source only) so each source derives its
# own directory; without this the first source's name would stick to the rest.
PLUGIN_NAME="${PLUGIN_NAME_OPT}"
HUB_VERSION=""
case "${SOURCE}" in
    # A Hub page URL (confluent.io/hub/owner/name) is what a browser lands on;
    # it serves JS-rendered HTML, not the plugin. Resolve it to the real archive
    # through the Hub API rather than downloading the page and failing later.
    https://www.confluent.io/hub/*|https://confluent.io/hub/*)
                                              SRC_KIND="hubpage" ;;
    http://*|https://*)                       SRC_KIND="url" ;;
    *)
        if [[ -d "${SOURCE}" ]]; then         SRC_KIND="dir"
        elif [[ -f "${SOURCE}" ]]; then
            case "${SOURCE}" in
                *.zip) SRC_KIND="zip" ;;
                *.jar) SRC_KIND="jar" ;;
                *) echo "[ERROR] '${SOURCE}' is neither .zip nor .jar." >&2; return 1 ;;
            esac
        elif [[ "${SOURCE}" == ./* || "${SOURCE}" == /* || "${SOURCE}" == ../* \
                || "${SOURCE}" == *.zip || "${SOURCE}" == *.jar ]]; then
            # Looks like a path, but nothing is there. Without this it would
            # fall through to the Hub branch below (any string with a '/' is a
            # valid-looking coordinate) and a typo'd path would be reported as a
            # Hub download failure, or silently staged under a name like
            # '.-nope.zip'.
            echo "[ERROR] '${SOURCE}' looks like a path but does not exist." >&2
            return 1
        elif [[ "${SOURCE}" == */* ]]; then   SRC_KIND="hub"
        else
            echo "[ERROR] '${SOURCE}' is not a URL, an existing path, or an owner/name[:version] Hub coordinate." >&2
            return 1
        fi ;;
esac

# ------------------------------------------------------------------------------
# Resolve a Hub page URL to its archive
# ------------------------------------------------------------------------------
# api.hub.confluent.io returns the plugin manifest, whose .archive.url is the
# ZIP that confluent-hub itself would fetch. Done here, on the workstation, so
# the failure is legible; the download still happens in-cluster afterwards.
HUB_VERSION=""
if [[ "${SRC_KIND}" == "hubpage" ]]; then
    _coord="${SOURCE#*://}"; _coord="${_coord#*/hub/}"; _coord="${_coord%%\?*}"; _coord="${_coord%/}"
    if [[ "${_coord}" != */* ]]; then
        echo "[ERROR] Cannot read an owner/name out of '${SOURCE}'." >&2; return 1
    fi
    _owner="${_coord%%/*}"; _plug="${_coord#*/}"
    # A page URL may carry a trailing version segment; the API wants two parts.
    _plug="${_plug%%/*}"

    echo "[INFO] Resolving Hub page for ${_owner}/${_plug}..."
    _meta="$(curl -sfL --retry 2 "https://api.hub.confluent.io/api/plugins/${_owner}/${_plug}" 2>/dev/null || true)"
    [[ -n "${_meta}" ]] || { echo "[ERROR] Confluent Hub API returned nothing for ${_owner}/${_plug}." >&2; return 1; }

    _resolved="$(printf '%s' "${_meta}" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(1)
a=d.get("archive") or {}
u=a.get("url")
if not u: raise SystemExit(1)
print(u); print(d.get("version") or ""); print(d.get("name") or "")' 2>/dev/null || true)"
    [[ -n "${_resolved}" ]] || { echo "[ERROR] No archive URL in the Hub manifest for ${_owner}/${_plug}." >&2; return 1; }

    SOURCE="$(printf '%s' "${_resolved}" | sed -n 1p)"
    HUB_VERSION="$(printf '%s' "${_resolved}" | sed -n 2p)"
    _hub_name="$(printf '%s' "${_resolved}" | sed -n 3p)"
    [[ -z "${PLUGIN_NAME}" && -n "${_hub_name}" ]] && PLUGIN_NAME="${_hub_name}"
    SRC_KIND="url"
    echo "[INFO] Resolved to ${SOURCE}"
fi

# Derive a directory name when one was not given.
if [[ -z "${PLUGIN_NAME}" ]]; then
    case "${SRC_KIND}" in
        hub) PLUGIN_NAME="${${SOURCE%%:*}//\//-}" ;;
        dir) PLUGIN_NAME="$(basename "${SOURCE%/}")" ;;
        *)   PLUGIN_NAME="$(basename "${SOURCE%%\?*}")"
             PLUGIN_NAME="${PLUGIN_NAME%.zip}"; PLUGIN_NAME="${PLUGIN_NAME%.jar}" ;;
    esac
fi
case "${PLUGIN_NAME}" in
    */*|..|.|"") echo "[ERROR] Bad plugin name '${PLUGIN_NAME}'; pass --name." >&2; return 1 ;;
esac
return 0
}

# The command-line --name, captured BEFORE the loop. _classify_source assigns to
# the global PLUGIN_NAME, so reading PLUGIN_NAME inside the loop would pick up
# the previous source's derived name and hand it to every later source - which
# then all resolve to the same directory and trip the duplicate check.
CLI_PLUGIN_NAME="${PLUGIN_NAME}"

# Classify every source up front, so a typo in the last one is reported before
# the PVC is created or anything is downloaded.
SRC_KINDS=(); PLUGIN_NAMES=(); RESOLVED_SOURCES=(); HUB_VERSIONS=(); FORCE_FLAGS=()
_bad_sources=0
for _n in {1..${#SOURCES[@]}}; do
    _s="${SOURCES[$_n]}"
    # A per-line --name from the manifest overrides the derived name for this
    # source only; PLUGIN_NAME_OPT is the command-line --name (single source).
    PLUGIN_NAME_OPT="${MANIFEST_NAMES[$_n]:-}"
    [[ -z "${PLUGIN_NAME_OPT}" ]] && PLUGIN_NAME_OPT="${CLI_PLUGIN_NAME}"
    if _classify_source "${_s}"; then
        RESOLVED_SOURCES+=("${SOURCE}"); SRC_KINDS+=("${SRC_KIND}")
        PLUGIN_NAMES+=("${PLUGIN_NAME}"); HUB_VERSIONS+=("${HUB_VERSION}")
        FORCE_FLAGS+=("${MANIFEST_FORCE[$_n]:-}")
    else
        _bad_sources=$(( _bad_sources + 1 ))
        $KEEP_GOING || exit 1
        echo "[WARN] --keep-going: skipping '${_s}'."
    fi
done
(( ${#RESOLVED_SOURCES[@]} > 0 )) || { echo "[ERROR] No usable source." >&2; exit 1; }

# Two sources resolving to the same directory would silently overwrite.
_dupes="$(printf '%s\n' "${PLUGIN_NAMES[@]}" | sort | uniq -d)"
if [[ -n "${_dupes}" ]]; then
    echo "[ERROR] More than one source resolves to the same plugin name:" >&2
    printf '[ERROR]   %s\n' ${=_dupes} >&2
    echo "[ERROR] Install them separately with --name to tell them apart." >&2
    exit 1
fi

echo "=============================================================================="
echo " Install Connect plugin - project '${NS}'"
echo "=============================================================================="
echo "  plugins : ${#RESOLVED_SOURCES[@]}"
for _i in {1..${#RESOLVED_SOURCES[@]}}; do
    echo "    ${_i}. ${PLUGIN_NAMES[$_i]}  (${SRC_KINDS[$_i]})"
    echo "       from ${RESOLVED_SOURCES[$_i]}"
    [[ -n "${HUB_VERSIONS[$_i]}" ]] && echo "       version ${HUB_VERSIONS[$_i]} (from Confluent Hub)"
    echo "       -> ${PLUGIN_DIR}/${PLUGIN_NAMES[$_i]}"
done
echo "  storage : $(_has_plugin_volume && echo "existing PVC ${CONFLUENT_CONNECT_PLUGIN_PVC}" || echo "new PVC ${CONFLUENT_CONNECT_PLUGIN_PVC} (${CONFLUENT_CONNECT_PLUGIN_SIZE})")"
if $NO_RESTART; then
    echo "  restart : skipped (--no-restart; plugin stays invisible until next restart)"
else
    echo "  restart : yes - ONE rollout after all plugins are staged"
fi
$KEEP_GOING && echo "  on error: --keep-going, install what works and report the rest"
echo ""

if $DRY_RUN; then echo "[INFO] --dry-run: no changes made."; exit 0; fi

if ! $ASSUME_YES; then
    printf "Continue? [y/N] "
    read -r _r; case "${_r}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 1 - attach the plugin PVC on first use
# ------------------------------------------------------------------------------
if ! _has_plugin_volume; then
    echo "[INFO] First run: creating PVC '${CONFLUENT_CONNECT_PLUGIN_PVC}' and attaching it."

    _sc_line=""
    [[ -n "${CONFLUENT_STORAGE_CLASS}" ]] && _sc_line="  storageClassName: ${CONFLUENT_STORAGE_CLASS}"
    oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CONFLUENT_CONNECT_PLUGIN_PVC}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: confluent
spec:
  accessModes:
    - ReadWriteOnce
${_sc_line}
  resources:
    requests:
      storage: ${CONFLUENT_CONNECT_PLUGIN_SIZE}
EOF

    # A fresh PVC mounts as root:root 0755, but the Connect image runs as a
    # non-root user, so it could not write into it. fsGroup makes kubelet chgrp
    # the volume and set the setgid bit, which is what makes it writable. Read
    # the gid off the running container rather than assuming 1000; OpenShift
    # overrides the uid from the namespace range but leaves the gid alone.
    _probe_pod="$(_connect_pod)"
    _fsgroup=""
    [[ -n "${_probe_pod}" ]] && _fsgroup="$(oc exec "${_probe_pod}" -n "${NS}" -- id -g 2>/dev/null | tr -dc '0-9' || true)"
    [[ -n "${_fsgroup}" && "${_fsgroup}" != "0" ]] || _fsgroup="1000"
    echo "[INFO] Volume will be group-owned by gid ${_fsgroup} (fsGroup)."

    # RWO means the old and new pods cannot both mount it during a rolling
    # update, which would wedge the rollout. Recreate avoids that.
    oc patch deployment connect -n "${NS}" --type=json -p "$(cat <<EOF
[
  {"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}},
  {"op":"add","path":"/spec/template/spec/securityContext","value":{"fsGroup":${_fsgroup}}},
  {"op":"add","path":"/spec/template/spec/volumes","value":[
    {"name":"connect-plugins","persistentVolumeClaim":{"claimName":"${CONFLUENT_CONNECT_PLUGIN_PVC}"}}]},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[
    {"name":"connect-plugins","mountPath":"${PLUGIN_DIR}"}]}
]
EOF
)"

    # Append our dir to whatever the install script set, preserving it.
    _cur_path="$(_plugin_path)"
    [[ -n "${_cur_path}" ]] || _cur_path="/usr/share/java,/usr/share/confluent-hub-components"
    case ",${_cur_path}," in
        *",${PLUGIN_DIR},"*) ;;
        *) _new_path="${_cur_path},${PLUGIN_DIR}"
           oc set env deployment/connect -n "${NS}" "CONNECT_PLUGIN_PATH=${_new_path}"
           echo "[INFO] CONNECT_PLUGIN_PATH -> ${_new_path}" ;;
    esac

    oc rollout status deployment/connect -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"
else
    echo "[INFO] Plugin volume already attached."
    # A volume attached before fsGroup was set stays root-owned and unwritable.
    # Repair it in place rather than making the caller delete the PVC.
    if [[ -z "$(oc get deployment connect -n "${NS}" \
          -o jsonpath='{.spec.template.spec.securityContext.fsGroup}' 2>/dev/null)" ]]; then
        _probe_pod="$(_wait_pod)"
        if ! oc exec "${_probe_pod}" -n "${NS}" -- sh -c "test -w '${PLUGIN_DIR}'" 2>/dev/null; then
            _fsgroup="$(oc exec "${_probe_pod}" -n "${NS}" -- id -g 2>/dev/null | tr -dc '0-9' || true)"
            [[ -n "${_fsgroup}" && "${_fsgroup}" != "0" ]] || _fsgroup="1000"
            echo "[INFO] ${PLUGIN_DIR} is not writable; setting fsGroup=${_fsgroup} and restarting."
            oc patch deployment connect -n "${NS}" --type=json \
                -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":${_fsgroup}}}]"
            oc rollout status deployment/connect -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"
        fi
    fi
fi

POD="$(_wait_pod)"
echo "[INFO] Using pod ${POD}."

# ------------------------------------------------------------------------------
# Steps 2 and 3, once per source
# ------------------------------------------------------------------------------
# Everything from the clobber check to the move into place is per-plugin. The
# PVC above and the rollout below are shared, which is the whole point: N
# plugins, ONE restart. Returns non-zero rather than exiting so --keep-going can
# carry on to the next source.
_install_one() {
local SOURCE="$1" SRC_KIND="$2" PLUGIN_NAME="$3" LINE_FORCE="${4:-}"
# --force is either run-wide (command line) or set on this manifest line.
local _force=false
{ $FORCE || [[ -n "${LINE_FORCE}" ]]; } && _force=true

# ------------------------------------------------------------------------------
# Step 2 - refuse to clobber unless --force
# ------------------------------------------------------------------------------
if oc exec "${POD}" -n "${NS}" -- sh -c "[ -e '${PLUGIN_DIR}/${PLUGIN_NAME}' ]" 2>/dev/null; then
    if ! $_force; then
        echo "[ERROR] '${PLUGIN_NAME}' is already installed. Re-run with --force to overwrite, or --name to install alongside." >&2
        return 1
    fi
    echo "[INFO] --force: replacing existing '${PLUGIN_NAME}'."
    oc exec "${POD}" -n "${NS}" -- rm -rf "${PLUGIN_DIR}/${PLUGIN_NAME}"
fi

# ------------------------------------------------------------------------------
# Step 3 - stage the plugin
# ------------------------------------------------------------------------------
# Staged next to the target and moved into place only on success, so a failed
# download never leaves a half-populated plugin dir for the worker to scan.
STAGE="${PLUGIN_DIR}/.staging-${PLUGIN_NAME}"
oc exec "${POD}" -n "${NS}" -- rm -rf "${STAGE}"
oc exec "${POD}" -n "${NS}" -- mkdir -p "${STAGE}"

_cleanup_stage() { oc exec "${POD}" -n "${NS}" -- rm -rf "${STAGE}" >/dev/null 2>&1 || true; }

case "${SRC_KIND}" in
    url)
        echo "[INFO] Downloading in-cluster: ${SOURCE}"
        # -f so an HTML error page is not silently unzipped as a plugin.
        oc exec "${POD}" -n "${NS}" -- sh -c \
            "curl -fSL --retry 3 -o '${STAGE}/plugin.zip' '${SOURCE}'" || {
            _cleanup_stage; echo "[ERROR] Download failed." >&2; return 1; }
        _unzip_in_pod "${POD}" "${STAGE}" "${STAGE}/plugin.zip" || {
            _cleanup_stage; echo "[ERROR] Not a valid ZIP archive." >&2; return 1; }
        ;;
    zip)
        echo "[INFO] Uploading $(basename "${SOURCE}")"
        oc exec -i "${POD}" -n "${NS}" -- sh -c "cat > '${STAGE}/plugin.zip'" < "${SOURCE}"
        _unzip_in_pod "${POD}" "${STAGE}" "${STAGE}/plugin.zip" || {
            _cleanup_stage; echo "[ERROR] Not a valid ZIP archive." >&2; return 1; }
        ;;
    jar)
        echo "[INFO] Uploading $(basename "${SOURCE}")"
        oc exec -i "${POD}" -n "${NS}" -- sh -c "cat > '${STAGE}/$(basename "${SOURCE}")'" < "${SOURCE}"
        ;;
    dir)
        echo "[INFO] Copying directory ${SOURCE}"
        oc cp "${SOURCE%/}/." "${NS}/${POD}:${STAGE}" || {
            _cleanup_stage; echo "[ERROR] Copy failed." >&2; return 1; }
        ;;
    hub)
        echo "[INFO] confluent-hub install ${SOURCE} (needs egress to Confluent Hub)"
        oc exec "${POD}" -n "${NS}" -- sh -c \
            "confluent-hub install --no-prompt --component-dir '${STAGE}' --worker-configs /dev/null '${SOURCE}'" || {
            _cleanup_stage
            echo "[ERROR] confluent-hub install failed - usually no egress to Confluent Hub." >&2
            echo "[INFO]  Download the ZIP on a connected host and pass it as a path instead." >&2
            return 1; }
        ;;
esac

# A Hub ZIP unpacks to a single owner-name-version/ wrapper; lift it so the
# plugin dir holds lib/ directly rather than one pointless level down.
oc exec "${POD}" -n "${NS}" -- sh -c "
    set -e
    cd '${STAGE}'
    n=\$(ls -1A | wc -l)
    if [ \"\$n\" -eq 1 ] && [ -d \"\$(ls -1A)\" ]; then
        inner=\$(ls -1A)
        mv \"\$inner\" ../.lift-${PLUGIN_NAME}
        cd .. && rm -rf '${STAGE}' && mv .lift-${PLUGIN_NAME} '${STAGE}'
    fi
"

# Sanity check: a plugin with no JAR anywhere is a bad download or wrong archive.
#
# Deliberately NOT 'find': the CP 8.x Connect images do not ship findutils, so
# the check failed with "find: command not found", which the 2>/dev/null hid and
# then reported as a bad download on a plugin that had downloaded perfectly.
# Globbing is a shell builtin and always present. Depth 3 covers every layout
# confluent-hub produces: uber JAR at the root, the usual lib/ subdirectory, and
# one extra level for archives that nest deeper.
if ! oc exec "${POD}" -n "${NS}" -- sh -c "
    set -- '${STAGE}'/*.jar '${STAGE}'/*/*.jar '${STAGE}'/*/*/*.jar
    for f; do [ -f \"\$f\" ] && exit 0; done
    exit 1
" 2>/dev/null; then
    _cleanup_stage
    echo "[ERROR] No .jar found in the staged plugin - wrong archive or a bad download." >&2
    return 1
fi

oc exec "${POD}" -n "${NS}" -- mv "${STAGE}" "${PLUGIN_DIR}/${PLUGIN_NAME}"
echo "[INFO] Staged at ${PLUGIN_DIR}/${PLUGIN_NAME}:"
oc exec "${POD}" -n "${NS}" -- sh -c "ls -1 '${PLUGIN_DIR}/${PLUGIN_NAME}' | head -10"
return 0
}

# Stage every plugin before restarting anything.
INSTALLED=(); FAILED=()
for _i in {1..${#RESOLVED_SOURCES[@]}}; do
    echo ""
    echo "------------------------------------------------------------------------------"
    echo " [${_i}/${#RESOLVED_SOURCES[@]}] ${PLUGIN_NAMES[$_i]}"
    echo "------------------------------------------------------------------------------"
    if _install_one "${RESOLVED_SOURCES[$_i]}" "${SRC_KINDS[$_i]}" "${PLUGIN_NAMES[$_i]}" "${FORCE_FLAGS[$_i]:-}"; then
        INSTALLED+=("${PLUGIN_NAMES[$_i]}")
    else
        FAILED+=("${PLUGIN_NAMES[$_i]}")
        if ! $KEEP_GOING; then
            echo "" >&2
            echo "[ERROR] '${PLUGIN_NAMES[$_i]}' failed. Stopping without restarting Connect." >&2
            if (( ${#INSTALLED[@]} > 0 )); then
                echo "[INFO] Already staged (on disk, NOT yet loaded): ${INSTALLED[*]}" >&2
                echo "[INFO] They load on the next restart, or re-run with --keep-going." >&2
            fi
            exit 1
        fi
        echo "[WARN] --keep-going: continuing after '${PLUGIN_NAMES[$_i]}'."
    fi
done

echo ""
echo "------------------------------------------------------------------------------"
echo " Staged ${#INSTALLED[@]}/${#RESOLVED_SOURCES[@]}: ${INSTALLED[*]:-none}"
(( ${#FAILED[@]} > 0 )) && echo " Failed  ${#FAILED[@]}: ${FAILED[*]}"
echo "------------------------------------------------------------------------------"

if (( ${#INSTALLED[@]} == 0 )); then
    echo "[ERROR] Nothing was staged; not restarting Connect." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 4 - restart so the worker scans the plugin path
# ------------------------------------------------------------------------------
if $NO_RESTART; then
    echo ""
    echo "[INFO] --no-restart: files are in place but the worker has not rescanned."
    echo "[INFO] Run 'oc rollout restart deployment/connect -n ${NS}' to load it."
    exit 0
fi

echo ""
echo "[INFO] Restarting Connect so the worker discovers the plugin..."
oc rollout restart deployment/connect -n "${NS}"
oc rollout status deployment/connect -n "${NS}" --timeout="${CONFLUENT_ROLLOUT_TIMEOUT}"

POD="$(_wait_pod)"

# The REST port answers a little after the pod reports Ready.
echo "[INFO] Waiting for the worker to answer..."
for _i in {1..30}; do
    if oc exec "${POD}" -n "${NS}" -- curl -sf "http://localhost:${CONFLUENT_CONNECT_PORT}/connector-plugins" >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

echo ""
echo "-- plugins now loaded --------------------------------------------------------"
oc exec "${POD}" -n "${NS}" -- curl -sf "http://localhost:${CONFLUENT_CONNECT_PORT}/connector-plugins" 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
for x in sorted(d, key=lambda i: i["class"]):
    print("  {:<70} {}".format(x["class"], x.get("type","")))
print("\n  {} plugin(s)".format(len(d)))' 2>/dev/null || echo "  (worker not answering yet - retry with --list)"

echo ""
echo "[INFO] Done. Configure an instance by POSTing to /connectors, e.g.:"
echo "       oc exec ${POD} -n ${NS} -- curl -sX POST -H 'Content-Type: application/json' \\"
echo "         --data @connector.json http://localhost:${CONFLUENT_CONNECT_PORT}/connectors"
