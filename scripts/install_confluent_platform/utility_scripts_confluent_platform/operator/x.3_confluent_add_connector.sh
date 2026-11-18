#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform (operator mode) - install a connector plugin into Kafka Connect
# ------------------------------------------------------------------------------
# Same command line as the scripts-mode x.3; the plugins end up in the Connect
# CR instead of a patched Deployment (plan 15.7):
#
#   owner/name[:version]               Confluent Hub coordinate -> Connect
#   https://www.confluent.io/hub/o/n   Hub page URL                spec.build.onDemand
#                                                                  .plugins.confluentHub
#   https://.../connector.zip          archive URL -> .plugins.url {name, archivePath,
#                                      checksum}; the sha512 is computed here after a
#                                      download to a temp file (the CRD requires it).
#                                      CFK fetches the archive from inside the pod.
#   ./connector.zip | ./x.jar | ./dir/ local sources -> PVC connect-plugins (RWX with
#                                      STG_CLASS_FILE, else RWO), mounted at
#                                      /mnt/local-plugins; the files are streamed in
#                                      with tar through a loader pod (or the running
#                                      Connect pod once it mounts the PVC).
#
# The plugin list lives in CONFLUENT_CONNECT_STATE_FILE (0600 JSON, written
# atomically); 1.1_confluent_install.sh renders the Connect CR from it. After a
# change this script re-runs 1.1 (CFK rolls Connect; waits use
# CONFLUENT_OPERATOR_CONNECT_TIMEOUT). When only the files on the PVC changed
# (the CR spec is the same), the Connect pods are restarted one by one so the
# worker rescans plugin.path. Never `oc rollout restart`.
#
# Usage:
#   ./x.3_confluent_add_connector.sh <source> [<source>...] [options]
#   ./x.3_confluent_add_connector.sh --file connectors.txt [options]
#   ./x.3_confluent_add_connector.sh --list
#   ./x.3_confluent_add_connector.sh --remove <name>
#
#   --file <p>    install every connector listed in a manifest file (one source
#     (-f)        per line, optional per-line --name / --force; a YAML list works)
#   --name <n>    plugin name (default: derived from the source); single source
#   --list        the state file and the worker's loaded connector plugins
#   --remove <n>  drop the plugin (state entry, and its PVC directory) and re-apply
#   --no-restart  update the state (and the PVC) but do not re-run 1.1
#   --keep-going  with several sources, install the ones that work
#   --force       replace an existing plugin of the same name
#   --yes         skip the confirmation prompt (default)
#   --dry-run     report what would change (renders the Connect CR from the new
#                 state into a temp dir and server-dry-runs the PVC/loader), change nothing
#
# Exit status: 0 ok, 1 error, 2 blocked (scripts-mode install in the namespace).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode) - install a connector/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

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

while (( $# > 0 )); do
    case "$1" in
        --file|-f)    h_need_value "$1" "${2:-}"; MANIFEST="$2"; shift 2 ;;
        --name)       h_need_value "$1" "${2:-}"; PLUGIN_NAME="$2"; shift 2 ;;
        --list)       DO_LIST=true; shift ;;
        --remove)     h_need_value "$1" "${2:-}"; REMOVE_NAME="$2"; shift 2 ;;
        --no-restart) NO_RESTART=true; shift ;;
        --keep-going) KEEP_GOING=true; shift ;;
        --force)      FORCE=true; shift ;;
        --yes|-y)     ASSUME_YES=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage; exit 0 ;;
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


export DRY_RUN

cfo_entry platform

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_CONNECT_PORT:=8083}"
PVC="${CONFLUENT_CONNECT_PLUGINS_PVC:-connect-plugins}"
STATE_FILE="${CONFLUENT_CONNECT_STATE_FILE}"
LOADER="connect-plugins-loader"
MOUNT="/mnt/local-plugins"
CONNECT_RES="$(cfo_resource Connect)"
INSTALL="${CF_PLATFORM_DIR}/1.1_confluent_install.sh"
_cfo_int "${CONFLUENT_OPERATOR_CONNECT_TIMEOUT:-}" 900; T_CONNECT="${REPLY}"
_cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; T_COMPONENT="${REPLY}"

WORK="$(_cfo_mktemp)"
trap 'rm -rf "${WORK}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

# ------------------------------------------------------------------------------
# The state file (contract 4.2): {"schema_version":1, "plugins":{"confluentHub":[...],"url":[...]},
# "local_plugins":{"enabled","pvc","dirs"}, "mounted_secrets":[...]}. Written atomically, 0600.
#   list --state F                     human listing
#   plan --state F --out O --pvc P     stdin {"add":[...], "remove":[...]} -> new state in O;
#                                      "CHANGE ..." lines, or "ERROR ..." lines and exit 1
# ------------------------------------------------------------------------------
_STATE_PY='
import json, os, sys, tempfile

def load(path, pvc):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except FileNotFoundError:
        d = {}
    except ValueError as exc:
        print("ERROR %s is not valid JSON (%s) - fix or remove it" % (path, exc))
        sys.exit(1)
    if not isinstance(d, dict):
        print("ERROR %s does not hold a JSON object" % path)
        sys.exit(1)
    d.setdefault("schema_version", 1)
    plugins = d.setdefault("plugins", {})
    plugins.setdefault("confluentHub", [])
    plugins.setdefault("url", [])
    local = d.setdefault("local_plugins", {})
    local.setdefault("enabled", False)
    local.setdefault("pvc", pvc)
    local.setdefault("dirs", [])
    d.setdefault("mounted_secrets", [])
    return d

def names(kind, e):
    if kind == "hub":
        return {e.get("name", ""), "%s/%s" % (e.get("owner", ""), e.get("name", "")), "%s-%s" % (e.get("owner", ""), e.get("name", ""))}
    return {e.get("name", "")}

def find(d, name):
    for i, e in enumerate(d["plugins"]["confluentHub"]):
        if name in names("hub", e):
            return "hub", i
    for i, e in enumerate(d["plugins"]["url"]):
        if name in names("url", e):
            return "url", i
    if name in d["local_plugins"]["dirs"]:
        return "local", d["local_plugins"]["dirs"].index(name)
    return None, None

def drop(d, kind, i):
    if kind == "hub":
        return d["plugins"]["confluentHub"].pop(i)
    if kind == "url":
        return d["plugins"]["url"].pop(i)
    return d["local_plugins"]["dirs"].pop(i)

def save(d, path):
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".connect-state-", dir=folder)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(d, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    opt = dict(zip(args[0::2], args[1::2]))
    d = load(opt["--state"], opt.get("--pvc", "connect-plugins"))
    if cmd == "list":
        for e in d["plugins"]["confluentHub"]:
            print("  confluentHub  %s/%s:%s" % (e.get("owner"), e.get("name"), e.get("version", "latest")))
        for e in d["plugins"]["url"]:
            print("  url           %s  %s" % (e.get("name"), e.get("archivePath")))
        for n in d["local_plugins"]["dirs"]:
            print("  local         %s  (PVC %s, %s)" % (n, d["local_plugins"]["pvc"], "mounted" if d["local_plugins"]["enabled"] else "not mounted"))
        for s in d["mounted_secrets"]:
            print("  secret        %s  (mounted at /mnt/secrets/%s)" % (s, s))
        if not (d["plugins"]["confluentHub"] or d["plugins"]["url"] or d["local_plugins"]["dirs"] or d["mounted_secrets"]):
            print("  (no plugins in the state file)")
        return 0
    req = json.load(sys.stdin)
    errors = []
    for name in req.get("remove", []):
        kind, i = find(d, name)
        if kind is None:
            errors.append("no plugin %r in %s (use --list)" % (name, opt["--state"]))
            continue
        drop(d, kind, i)
        print("CHANGE remove %s %s" % (kind, name))
    for e in req.get("add", []):
        kind, name, force = e["kind"], e["name"], e.get("force", False)
        old, i = find(d, name)
        if old is not None:
            if not force:
                errors.append("%r is already installed (%s). Re-run with --force to replace it, or --name to install alongside" % (name, old))
                continue
            drop(d, old, i)
            print("CHANGE replace %s %s" % (old, name))
        if kind == "hub":
            d["plugins"]["confluentHub"].append({"owner": e["owner"], "name": e["hub_name"], "version": e.get("version") or "latest"})
        elif kind == "url":
            d["plugins"]["url"].append({"name": name, "archivePath": e["archivePath"], "checksum": e["checksum"]})
        else:
            d["local_plugins"]["dirs"].append(name)
            d["local_plugins"]["pvc"] = opt.get("--pvc", d["local_plugins"]["pvc"])
        print("CHANGE add %s %s" % (kind, name))
    d["local_plugins"]["enabled"] = bool(d["local_plugins"]["dirs"])
    if errors:
        for err in errors:
            print("ERROR " + err)
        return 1
    save(d, opt["--out"])
    return 0

sys.exit(main())
'
_state() { cfo_python -c "${_STATE_PY}" "$@"; }

# Ready Connect pod that mounts the plugins PVC (empty when none).
_connect_pod_with_pvc() {
    local pods p claim ready
    pods="$(oc get pods -n "${NS}" -l "app=${CF_CONNECT_CR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    for p in ${(f)pods}; do
        claim="$(oc get pod "${p}" -n "${NS}" -o jsonpath="{.spec.volumes[?(@.persistentVolumeClaim.claimName==\"${PVC}\")].name}" 2>/dev/null || true)"
        ready="$(oc get pod "${p}" -n "${NS}" -o jsonpath='{.status.containerStatuses[?(@.name=="connect")].ready}' 2>/dev/null || true)"
        if [[ -n "${claim}" && "${ready}" == true ]]; then print -r -- "${p}"; return 0; fi
    done
    return 0
}

# _pod_exec <pod> <args...> - oc exec with the Connect container picked when the pod is Connect's.
_pod_exec() {
    local pod="$1"; shift
    if [[ "${pod}" == "${LOADER}" ]]; then
        oc exec "${pod}" -n "${NS}" -- "$@"
    else
        oc exec "${pod}" -n "${NS}" -c connect -- "$@"
    fi
}
# _pod_exec_in <pod> <args...> - the same with stdin attached (the tar stream).
_pod_exec_in() {
    local pod="$1"; shift
    if [[ "${pod}" == "${LOADER}" ]]; then
        oc exec -i "${pod}" -n "${NS}" -- "$@"
    else
        oc exec -i "${pod}" -n "${NS}" -c connect -- "$@"
    fi
}

# ------------------------------------------------------------------------------
# --list
# ------------------------------------------------------------------------------
if $DO_LIST; then
    echo "=============================================================================="
    echo " Kafka Connect plugins (operator mode) - project '${NS}'"
    echo "=============================================================================="
    echo "  state file : ${STATE_FILE}"
    _state list --state "${STATE_FILE}" --pvc "${PVC}"
    echo ""
    echo "-- loaded by the worker ------------------------------------------------------"
    oc exec "pod/${CF_CONNECT_CR}-0" -n "${NS}" -c connect -- curl -sf "http://localhost:${CONFLUENT_CONNECT_PORT}/connector-plugins" 2>/dev/null \
        | cfo_python -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print("  (worker not answering)"); raise SystemExit(0)
for x in sorted(d, key=lambda i: i["class"]):
    print("  {:<70} {}".format(x["class"], x.get("type","")))
print("\n  {} plugin(s)".format(len(d)))' 2>/dev/null || echo "  (worker not answering)"
    exit 0
fi

if [[ -z "$(oc get "${CONNECT_RES}" "${CF_CONNECT_CR}" -n "${NS}" -o name 2>/dev/null || true)" ]] && ! $DRY_RUN; then
    echo "[ERROR] No Connect CR '${CF_CONNECT_CR}' in '${NS}'. Is CONFLUENT_INSTALL_CONNECT=true (and 1.1 run)?" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Classify the sources (operator mode: Hub coordinates and Hub pages are CFK
# confluentHub plugins; archive URLs are CFK url plugins; local files go to the PVC)
# ------------------------------------------------------------------------------
# Sets SRC_KIND (hub|url|local), PLUGIN_NAME, HUB_OWNER, HUB_NAME, HUB_VERSION, SOURCE, LOCAL_KIND (zip|jar|dir).
_classify() {
    SOURCE="$1" SRC_KIND="" LOCAL_KIND="" HUB_OWNER="" HUB_NAME="" HUB_VERSION=""
    PLUGIN_NAME="${PLUGIN_NAME_OPT}"
    case "${SOURCE}" in
        https://www.confluent.io/hub/*|https://confluent.io/hub/*)
            local coord="${SOURCE#*://}"; coord="${coord#*/hub/}"; coord="${coord%%\?*}"; coord="${coord%/}"
            [[ "${coord}" == */* ]] || { echo "[ERROR] Cannot read an owner/name out of '${SOURCE}'." >&2; return 1; }
            HUB_OWNER="${coord%%/*}"; HUB_NAME="${coord#*/}"; HUB_NAME="${HUB_NAME%%/*}"
            local meta=""
            meta="$(curl -sfL --retry 2 "https://api.hub.confluent.io/api/plugins/${HUB_OWNER}/${HUB_NAME}" 2>/dev/null || true)"
            HUB_VERSION="$(print -r -- "${meta}" | cfo_python -c 'import sys,json
try: print(json.load(sys.stdin).get("version") or "")
except Exception: pass' 2>/dev/null || true)"
            [[ -n "${HUB_VERSION}" ]] || { HUB_VERSION=latest; echo "[INFO] Hub API not reachable for ${HUB_OWNER}/${HUB_NAME}; using version 'latest' (CFK resolves it)."; }
            SRC_KIND=hub ;;
        http://*|https://*)
            SRC_KIND=url ;;
        *)
            if [[ -d "${SOURCE}" ]]; then SRC_KIND=local LOCAL_KIND=dir
            elif [[ -f "${SOURCE}" ]]; then
                case "${SOURCE}" in
                    *.zip) SRC_KIND=local LOCAL_KIND=zip ;;
                    *.jar) SRC_KIND=local LOCAL_KIND=jar ;;
                    *) echo "[ERROR] '${SOURCE}' is neither .zip nor .jar." >&2; return 1 ;;
                esac
            elif [[ "${SOURCE}" == ./* || "${SOURCE}" == /* || "${SOURCE}" == ../* \
                    || "${SOURCE}" == *.zip || "${SOURCE}" == *.jar ]]; then
                echo "[ERROR] '${SOURCE}' looks like a path but does not exist." >&2; return 1
            elif [[ "${SOURCE}" == */* ]]; then
                SRC_KIND=hub
                local coord="${SOURCE%%:*}"
                HUB_OWNER="${coord%%/*}"; HUB_NAME="${coord#*/}"
                HUB_VERSION="latest"; [[ "${SOURCE}" == *:* ]] && HUB_VERSION="${SOURCE##*:}"
                [[ -n "${HUB_OWNER}" && -n "${HUB_NAME}" && "${HUB_NAME}" != */* ]] \
                    || { echo "[ERROR] '${SOURCE}' is not an owner/name[:version] Hub coordinate." >&2; return 1; }
            else
                echo "[ERROR] '${SOURCE}' is not a URL, an existing path, or an owner/name[:version] Hub coordinate." >&2
                return 1
            fi ;;
    esac
    if [[ -z "${PLUGIN_NAME}" ]]; then
        case "${SRC_KIND}" in
            hub) PLUGIN_NAME="${HUB_OWNER}-${HUB_NAME}" ;;
            *)   if [[ "${LOCAL_KIND}" == dir ]]; then
                     PLUGIN_NAME="$(basename "${SOURCE%/}")"
                 else
                     PLUGIN_NAME="$(basename "${SOURCE%%\?*}")"
                     PLUGIN_NAME="${PLUGIN_NAME%.zip}"; PLUGIN_NAME="${PLUGIN_NAME%.jar}"
                 fi ;;
        esac
    fi
    case "${PLUGIN_NAME}" in
        */*|..|.|""|.*) echo "[ERROR] Bad plugin name '${PLUGIN_NAME}'; pass --name." >&2; return 1 ;;
    esac
    return 0
}

CLI_PLUGIN_NAME="${PLUGIN_NAME}"
typeset -a KINDS=() NAMES=() RESOLVED=() LKINDS=() HOWNER=() HNAME=() HVER=() FORCES=()
if [[ -z "${REMOVE_NAME}" ]]; then
    for (( _n = 1; _n <= ${#SOURCES}; _n++ )); do
        PLUGIN_NAME_OPT="${MANIFEST_NAMES[$_n]:-}"
        [[ -z "${PLUGIN_NAME_OPT}" ]] && PLUGIN_NAME_OPT="${CLI_PLUGIN_NAME}"
        if _classify "${SOURCES[$_n]}"; then
            KINDS+=("${SRC_KIND}") NAMES+=("${PLUGIN_NAME}") RESOLVED+=("${SOURCE}") LKINDS+=("${LOCAL_KIND:--}")
            HOWNER+=("${HUB_OWNER:--}") HNAME+=("${HUB_NAME:--}") HVER+=("${HUB_VERSION:--}")
            if $FORCE || [[ -n "${MANIFEST_FORCE[$_n]:-}" ]]; then FORCES+=(true); else FORCES+=(false); fi
        else
            $KEEP_GOING || exit 1
            echo "[WARN] --keep-going: skipping '${SOURCES[$_n]}'."
        fi
    done
    (( ${#NAMES[@]} > 0 )) || { echo "[ERROR] No usable source." >&2; exit 1; }
    _dupes="$(printf '%s\n' "${NAMES[@]}" | sort | uniq -d)"
    if [[ -n "${_dupes}" ]]; then
        echo "[ERROR] More than one source resolves to the same plugin name:" >&2
        printf '[ERROR]   %s\n' ${=_dupes} >&2
        echo "[ERROR] Install them separately with --name to tell them apart." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# URL plugins: the CRD requires a checksum; download once and hash it here
# ------------------------------------------------------------------------------
typeset -a CHECKSUMS=()
for (( _i = 1; _i <= ${#NAMES}; _i++ )); do
    CHECKSUMS+=("")
    [[ "${KINDS[$_i]}" == url ]] || continue
    if $DRY_RUN; then
        echo "  [DRY-RUN] curl -fSL ${RESOLVED[$_i]} (sha512 computed after the download)"
        CHECKSUMS[$_i]="dry-run-checksum-not-computed"
        continue
    fi
    echo "[INFO] Downloading ${RESOLVED[$_i]} to compute its sha512 (CFK fetches it again from the pod)."
    _f="${WORK}/download-${_i}"
    if ! curl -fSL --retry 3 -o "${_f}" "${RESOLVED[$_i]}"; then
        echo "[ERROR] Download of ${RESOLVED[$_i]} failed." >&2
        $KEEP_GOING || exit 1
        KINDS[$_i]=skip; continue
    fi
    if ! cfo_python -c 'import sys, zipfile
p = sys.argv[1]
if zipfile.is_zipfile(p):
    sys.exit(0 if any(n.endswith(".jar") for n in zipfile.ZipFile(p).namelist()) else 1)
sys.exit(0)' "${_f}"; then
        echo "[ERROR] No .jar in ${RESOLVED[$_i]} - wrong archive or a bad download." >&2
        $KEEP_GOING || exit 1
        KINDS[$_i]=skip; continue
    fi
    CHECKSUMS[$_i]="$(cfo_python -c 'import hashlib, sys
h = hashlib.sha512()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())' "${_f}")"
    rm -f "${_f}"
done

# _plan_json <only-local-ok> - the change request for the state helper (stdin JSON).
_plan_json() {
    local -a parts=()
    local i
    for (( i = 1; i <= ${#NAMES}; i++ )); do
        [[ "${KINDS[$i]}" == skip ]] && continue
        if [[ "${KINDS[$i]}" == local && -n "${1:-}" ]] && (( ! ${STAGED[(Ie)${NAMES[$i]}]} )); then
            continue
        fi
        parts+=("$(cfo_python -c 'import json, sys
k, n, src, ho, hn, hv, cs, force = sys.argv[1:9]
e = {"kind": k, "name": n, "force": force == "true"}
if k == "hub":
    e.update(owner=ho, hub_name=hn, version=hv)
elif k == "url":
    e.update(archivePath=src, checksum=cs)
print(json.dumps(e))' "${KINDS[$i]}" "${NAMES[$i]}" "${RESOLVED[$i]}" "${HOWNER[$i]}" "${HNAME[$i]}" "${HVER[$i]}" \
            "${CHECKSUMS[$i]}" "${FORCES[$i]}")")
    done
    local rm="[]"
    [[ -n "${REMOVE_NAME}" ]] && rm="$(cfo_python -c 'import json,sys; print(json.dumps([sys.argv[1]]))' "${REMOVE_NAME}")"
    print -r -- "{\"add\": [${(j:, :)parts}], \"remove\": ${rm}}"
}

typeset -a STAGED=()
if [[ -n "${REMOVE_NAME}" ]]; then
    case "${REMOVE_NAME}" in
        */*|..|.|"") echo "[ERROR] --remove takes a plain plugin name." >&2; exit 1 ;;
    esac
fi

# Validate the whole change against the state file before anything is staged.
_plan_rc=0
_plan_out="$(_plan_json | _state plan --state "${STATE_FILE}" --out "${WORK}/state.json" --pvc "${PVC}")" || _plan_rc=$?
if (( _plan_rc != 0 )); then
    print -r -- "${_plan_out}" | sed -n 's/^ERROR /[ERROR] /p' >&2
    exit 1
fi
_removed_local=false
[[ -n "${REMOVE_NAME}" && "${_plan_out}" == *"CHANGE remove local "* ]] && _removed_local=true
_has_local=false
(( ${KINDS[(Ie)local]} )) && _has_local=true

echo "=============================================================================="
echo " Connect plugins (operator mode) - project '${NS}'"
echo "=============================================================================="
if [[ -n "${REMOVE_NAME}" ]]; then
    echo "  remove  : ${REMOVE_NAME}"
else
    echo "  plugins : ${#NAMES[@]}"
    for (( _i = 1; _i <= ${#NAMES}; _i++ )); do
        [[ "${KINDS[$_i]}" == skip ]] && continue
        case "${KINDS[$_i]}" in
            hub)   echo "    ${_i}. ${NAMES[$_i]}  (confluentHub ${HOWNER[$_i]}/${HNAME[$_i]}:${HVER[$_i]})" ;;
            url)   echo "    ${_i}. ${NAMES[$_i]}  (url ${RESOLVED[$_i]})" ;;
            local) echo "    ${_i}. ${NAMES[$_i]}  (local ${LKINDS[$_i]} ${RESOLVED[$_i]} -> PVC ${PVC}:${MOUNT}/${NAMES[$_i]})" ;;
        esac
    done
fi
echo "  state   : ${STATE_FILE}"
print -r -- "${_plan_out}" | sed -n 's/^CHANGE /            /p'
if $NO_RESTART; then
    echo "  apply   : skipped (--no-restart; re-run 1.1_confluent_install.sh to apply)"
else
    echo "  apply   : re-run 1.1_confluent_install.sh (CFK rolls Connect)"
fi
echo ""

# ------------------------------------------------------------------------------
# --dry-run: render the Connect CR from the new state into a temp dir
# ------------------------------------------------------------------------------
if $DRY_RUN; then
    _rc=0
    ( CONFLUENT_CONNECT_STATE_FILE="${WORK}/state.json"; cfo_render platform "${WORK}/render" ) || _rc=$?
    if (( _rc == 0 )); then
        _cf="$(ls "${WORK}/render/platform/"*-connect-connect.yaml 2>/dev/null | head -1 || true)"
        if [[ -n "${_cf}" ]]; then
            echo "  [DRY-RUN] Connect CR from the new state (${_cf:t}):"
            cfo_python -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
spec = d.get("spec") or {}
out = {k: spec[k] for k in ("build", "mountedVolumes", "mountedSecrets") if k in spec}
over = [x for x in ((spec.get("configOverrides") or {}).get("server") or []) if x.startswith(("plugin.path", "config.providers"))]
if over:
    out["configOverrides.server"] = over
print(yaml.safe_dump(out or {"build": None}, sort_keys=False, default_flow_style=False), end="")' "${_cf}" | sed 's/^/    /'
        else
            echo "  [DRY-RUN] (Connect is disabled in the config - no Connect CR rendered)"
        fi
    else
        echo "[WARN] Rendering the Connect CR from the new state failed (see above)." >&2
    fi
    if ${_has_local}; then
        cfo_render connect-plugins "${WORK}/render" '{"job_name": "connect-plugins-loader"}' \
            && cfo_apply_manifest "${CFO_MANIFEST}" || echo "[WARN] Dry run of the plugins PVC / loader failed." >&2
    fi
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if ! $ASSUME_YES; then
    cf_continue_or_abort
fi

# ------------------------------------------------------------------------------
# Local sources (and a local --remove): the plugins PVC
# ------------------------------------------------------------------------------
_loader_used=false
POD=""
_pick_pod() {
    POD="$(_connect_pod_with_pvc)"
    [[ -n "${POD}" ]] && { echo "[INFO] Using the Connect pod ${POD} (it mounts PVC ${PVC})."; return 0; }
    echo "[INFO] Starting the loader pod ${LOADER} for PVC ${PVC}."
    local root="${CF_RENDER_ROOT}/cfk"
    cfo_render connect-plugins "${root}" '{"job_name": "connect-plugins-loader"}' || return 1
    cfo_apply_manifest "${CFO_MANIFEST}" || return 1
    _loader_used=true
    local e=0 st
    while true; do
        st="$(oc get pod "${LOADER}" -n "${NS}" -o jsonpath='{.status.phase}/{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
        echo "  [${e}s/${T_COMPONENT}s] Pod ${LOADER}: ${st:-pending}"
        [[ "${st}" == Running/true ]] && break
        if [[ "${st}" == Failed/* || "${st}" == Succeeded/* ]] || (( e >= T_COMPONENT )); then
            echo "[ERROR] Loader pod ${LOADER} not ready (${st:-none}). A ReadWriteOnce PVC mounted by a Connect pod on" >&2
            echo "[ERROR] another node blocks it: set STG_CLASS_FILE (RWX) or retry while Connect runs with the PVC." >&2
            oc describe pod "${LOADER}" -n "${NS}" 2>/dev/null | tail -n 15 >&2 || true
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
    POD="${LOADER}"
}
_cleanup_loader() {
    ${_loader_used} || return 0
    oc delete pod "${LOADER}" -n "${NS}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
    echo "[INFO] Loader pod ${LOADER} deleted."
}

# _stage_local <i> - unpack source i on this machine, stream it with tar into <POD>:<MOUNT>/<name>.
_stage_local() {
    local i="$1" name="${NAMES[$1]}" src="${RESOLVED[$1]}" kind="${LKINDS[$1]}" dir="${WORK}/stage-$1"
    mkdir -p "${dir}/${name}"
    case "${kind}" in
        zip) cfo_python -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "${src}" "${dir}/${name}" \
                 || { echo "[ERROR] '${src}' is not a valid ZIP archive." >&2; return 1; } ;;
        jar) cp "${src}" "${dir}/${name}/" || return 1 ;;
        dir) cp -R "${src%/}/." "${dir}/${name}/" || return 1 ;;
    esac
    # A Hub ZIP unpacks to a single wrapper directory; lift it (as the scripts-mode x.3).
    local -a top=("${dir}/${name}"/*(DN))
    if (( ${#top} == 1 )) && [[ -d "${top[1]}" ]]; then
        mv "${top[1]}" "${dir}/.lift" && rmdir "${dir}/${name}" && mv "${dir}/.lift" "${dir}/${name}"
    fi
    local -a jars=("${dir}/${name}"/*.jar(N) "${dir}/${name}"/*/*.jar(N) "${dir}/${name}"/*/*/*.jar(N))
    (( ${#jars} )) || { echo "[ERROR] No .jar found in '${src}' - wrong archive." >&2; return 1; }
    if _pod_exec "${POD}" sh -c "[ -e '${MOUNT}/${name}' ]" 2>/dev/null; then
        if [[ "${FORCES[$i]}" != true ]]; then
            echo "[ERROR] '${name}' is already on PVC ${PVC}. Re-run with --force to overwrite, or --name to install alongside." >&2
            return 1
        fi
        echo "[INFO] --force: replacing ${MOUNT}/${name}."
        _pod_exec "${POD}" rm -rf "${MOUNT}/${name}" || return 1
    fi
    local stage="${MOUNT}/.staging-${name}"
    _pod_exec "${POD}" sh -c "rm -rf '${stage}' && mkdir -p '${stage}'" || return 1
    echo "[INFO] Streaming ${src} -> ${POD}:${MOUNT}/${name} (tar)"
    if ! COPYFILE_DISABLE=1 tar -C "${dir}/${name}" -cf - . | _pod_exec_in "${POD}" tar -x -C "${stage}"; then
        _pod_exec "${POD}" rm -rf "${stage}" >/dev/null 2>&1 || true
        echo "[ERROR] Copying ${name} into the PVC failed." >&2
        return 1
    fi
    _pod_exec "${POD}" mv "${stage}" "${MOUNT}/${name}" || return 1
    rm -rf "${dir}"
    echo "[INFO] Staged at ${MOUNT}/${name}."
}

if ${_has_local} || ${_removed_local}; then
    _pick_pod || { _cleanup_loader; exit 1; }
    if ! _pod_exec "${POD}" sh -c 'command -v tar' >/dev/null 2>&1; then
        _cleanup_loader
        echo "[ERROR] Pod ${POD} has no tar, which the copy needs. Use an image with tar" >&2
        echo "[ERROR] (CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE, default registry.access.redhat.com/ubi9/ubi:latest)." >&2
        exit 1
    fi
    if ${_removed_local}; then
        echo "[INFO] Removing ${MOUNT}/${REMOVE_NAME} from PVC ${PVC}."
        _pod_exec "${POD}" rm -rf "${MOUNT}/${REMOVE_NAME}" || { _cleanup_loader; echo "[ERROR] Removing the directory failed." >&2; exit 1; }
    fi
    _i=0
    _nl=0
    for (( _j = 1; _j <= ${#NAMES}; _j++ )); do [[ "${KINDS[$_j]}" == local ]] && (( _nl += 1 )); done
    for (( _j = 1; _j <= ${#NAMES}; _j++ )); do
        [[ "${KINDS[$_j]}" == local ]] || continue
        (( _i += 1 ))
        echo "--- [${_i}/${_nl}] ${NAMES[$_j]}"
        if _stage_local "${_j}"; then
            STAGED+=("${NAMES[$_j]}")
        else
            if ! $KEEP_GOING; then
                _cleanup_loader
                echo "[ERROR] '${NAMES[$_j]}' failed. Stopping; the state file is unchanged." >&2
                (( ${#STAGED} )) && echo "[INFO] Already on the PVC (not in the state file yet): ${STAGED[*]}" >&2
                exit 1
            fi
            echo "[WARN] --keep-going: continuing after '${NAMES[$_j]}'."
        fi
    done
    _cleanup_loader
fi

# ------------------------------------------------------------------------------
# Write the state (only what was staged)
# ------------------------------------------------------------------------------
_plan_rc=0
_plan_out="$(_plan_json staged | _state plan --state "${STATE_FILE}" --out "${STATE_FILE}" --pvc "${PVC}")" || _plan_rc=$?
if (( _plan_rc != 0 )); then
    print -r -- "${_plan_out}" | sed -n 's/^ERROR /[ERROR] /p' >&2
    exit 1
fi
if [[ "${_plan_out}" != *CHANGE* ]]; then
    echo "[ERROR] Nothing could be installed; the state file is unchanged." >&2
    exit 1
fi
echo "[INFO] State written: ${STATE_FILE} (0600)."

if $NO_RESTART; then
    echo "[INFO] --no-restart: the Connect CR is not re-applied. Run ${INSTALL:t} to apply the plugins."
    exit 0
fi

# ------------------------------------------------------------------------------
# Re-apply (1.1 renders the Connect CR from the state; CFK rolls Connect)
# ------------------------------------------------------------------------------
_gen_before="$(oc get "${CONNECT_RES}" "${CF_CONNECT_CR}" -n "${NS}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"
echo ""
echo "[INFO] Re-running ${INSTALL:t} so CFK reconciles Connect..."
_rc=0
zsh "${INSTALL}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] ${INSTALL:t} exited ${_rc}." >&2; exit "${_rc}"; }
_gen_after="$(oc get "${CONNECT_RES}" "${CF_CONNECT_CR}" -n "${NS}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"

if { (( ${#STAGED} )) || ${_removed_local}; } && [[ -n "${_gen_before}" && "${_gen_before}" == "${_gen_after}" ]]; then
    # CONTRACT-DEVIATION: the contract expects CFK to roll Connect. With only new files on an already mounted PVC
    # the CR spec is unchanged and CFK does not roll, so the Connect pods are deleted one at a time (the
    # StatefulSet recreates them) and the CR is waited on with the Connect timeout. No `oc rollout restart`.
    echo "[INFO] The Connect CR is unchanged (only files on PVC ${PVC} changed) - restarting the Connect pods so the worker rescans plugin.path."
    for _p in ${(f)"$(oc get pods -n "${NS}" -l "app=${CF_CONNECT_CR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"}; do
        _uid="$(oc get pod "${_p}" -n "${NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
        oc delete pod "${_p}" -n "${NS}" --wait=false >/dev/null || { echo "[ERROR] Deleting pod ${_p} failed." >&2; exit 1; }
        # Wait for the replacement pod itself (new uid, connect container ready): the CR status can still read
        # RUNNING right after the delete, which would let the next pod go down at the same time.
        _e=0
        while true; do
            _now="$(oc get pod "${_p}" -n "${NS}" -o jsonpath='{.metadata.uid} {.status.containerStatuses[?(@.name=="connect")].ready}' 2>/dev/null || true)"
            [[ -n "${_now}" && "${_now%% *}" != "${_uid}" && "${_now##* }" == true ]] && break
            echo "  [${_e}s/${T_CONNECT}s] Pod ${_p}: restarting"
            if (( _e >= T_CONNECT )); then
                echo "[ERROR] Pod ${_p} not ready again after ${T_CONNECT}s: oc describe pod ${_p} -n ${NS}" >&2
                exit 1
            fi
            sleep "${CFO_POLL_INTERVAL}"
            _e=$(( _e + CFO_POLL_INTERVAL ))
        done
        _rc=0
        cfo_wait_crs "${NS}" "${T_CONNECT}" "Connect/${CF_CONNECT_CR}" || _rc=$?
        (( _rc == 0 )) || { echo "[ERROR] Connect/${CF_CONNECT_CR} is not ready after restarting ${_p}." >&2; exit 1; }
    done
fi

echo ""
echo "-- plugins now loaded --------------------------------------------------------"
oc exec "pod/${CF_CONNECT_CR}-0" -n "${NS}" -c connect -- curl -sf "http://localhost:${CONFLUENT_CONNECT_PORT}/connector-plugins" 2>/dev/null \
    | cfo_python -c 'import sys,json
d=json.load(sys.stdin)
for x in sorted(d, key=lambda i: i["class"]):
    print("  {:<70} {}".format(x["class"], x.get("type","")))
print("\n  {} plugin(s)".format(len(d)))' 2>/dev/null || echo "  (worker not answering yet - retry with --list)"
echo ""
echo "[INFO] Done. Configure an instance with POST /connectors (REST) or, with CONFLUENT_CONNECTOR_MANAGEMENT=cr, a Connector CR."
