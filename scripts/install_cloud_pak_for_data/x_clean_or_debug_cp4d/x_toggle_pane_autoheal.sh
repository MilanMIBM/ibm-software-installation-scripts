#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIX_DIR="${SCRIPT_DIR}/cluster_fixes/pane_autoheal"  # env_bootstrap.sh reassigns SCRIPT_DIR
# Load only the CP4D config (cpd_vars.sh) so another configs/*/ file can't
# redirect OC_LOGIN to a different cluster. Override with ENV_TARGET=<name|path>.
: "${ENV_TARGET:=cpd}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# --- Options
# Toggles a browser-side auto-heal for the CP4D UI error
#   "Oops, the pane didn't load."
# (Elyra common-properties error boundary). A small JS, served and injected into
# every CPD HTML page by ibm-nginx through a ZenExtension, presses the panel's
# Revert button (= re-render with the same values) up to 3x with backoff and
# beacons each occurrence (with the JS stack) to the ibm-nginx log.
# Plan: .claude/plans/cpd-pane-didnt-load-autoheal-plan.md
#
#   --action=toggle    ->  on if off, off if on (default)
#   --action=on        ->  validate (nginx -t dry run in ibm-nginx-tester), apply, verify
#   --action=off       ->  remove the ZenExtension, verify the endpoint is gone
#   --action=status    ->  state of the CR, nginx pods, JS endpoint, page injection, beacons
#   --action=validate  ->  only the nginx -t dry run, changes nothing
#   --preview=true     ->  print the ZenExtension that "on" would apply, change nothing
#   --namespace=<ns>   ->  CPD instance namespace (default: PROJECT_CPD_INST_OPERANDS)
#   --since=<dur>      ->  beacon window for status (default 24h)
#   --timeout=<sec>    ->  wait limit for apply/removal (default 420)
ACTION=toggle
PREVIEW=false
NS="${PROJECT_CPD_INST_OPERANDS:-}"
SINCE=24h
TIMEOUT=420

for arg in "$@"; do
    case "${arg}" in
        --action=*)     ACTION="${arg#--action=}" ;;
        --preview=*)    PREVIEW="${arg#--preview=}" ;;
        --namespace=*)  NS="${arg#--namespace=}" ;;
        --since=*)      SINCE="${arg#--since=}" ;;
        --timeout=*)    TIMEOUT="${arg#--timeout=}" ;;
        *) echo "[ERROR] Unknown option: ${arg}" >&2; exit 1 ;;
    esac
done
case "${ACTION}" in toggle|on|off|status|validate) ;; *) echo "[ERROR] --action must be toggle|on|off|status|validate" >&2; exit 1 ;; esac
[[ -z "${NS}" ]] && { echo "[ERROR] No namespace: set PROJECT_CPD_INST_OPERANDS or pass --namespace=" >&2; exit 1; }

EXT_NAME="cpd-pane-autoheal"
JS_FILE="${FIX_DIR}/autoheal.js"
SNIPPET_FILE="${FIX_DIR}/nginx_snippet.conf"
VALIDATE_DIR="/nginx_data/tmp/cpd-pane-autoheal-validate"
# Content hash = version: a changed JS/snippet is re-applied and verifiable end to end.
VERSION="1-$(cat "${JS_FILE}" "${SNIPPET_FILE}" | shasum | cut -c1-8)"

# Rendered nginx snippet and the ZenExtension (JSON). The JS goes into Lua long
# strings split at line boundaries into chunks below OpenResty's ~4 KB inline
# Lua block limit (one set_by_lua_block variable per chunk).
render_snippet() {
    python3 -I - "${SNIPPET_FILE}" "${JS_FILE}" "${VERSION}" <<'EOF'
import sys
snippet, js, version = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
js = js.replace("@@VERSION@@", version)
if "]==]" in js:
    sys.exit("autoheal.js must not contain ']==]'")
chunks, cur = [], ""
for line in js.splitlines(keepends=True):
    if len(line) > 3000:
        sys.exit("autoheal.js has a line longer than 3000 bytes")
    if len(cur) + len(line) > 3000:
        chunks.append(cur); cur = ""
    cur += line
chunks.append(cur)
names = [f"$cpd_pane_autoheal_js_{i + 1}" for i in range(len(chunks))]
sets = "\n".join(f"    set_by_lua_block {n} {{ return [==[{c}]==] }}" for n, c in zip(names, chunks))
vars_ = ", ".join(f"ngx.var.{n[1:]}" for n in names)
sys.stdout.write(snippet.replace("@@AUTOHEAL_JS_SETS@@", sets)
                        .replace("@@AUTOHEAL_JS_VARS@@", vars_)
                        .replace("@@VERSION@@", version))
EOF
}

render_cr() {
    render_snippet | python3 -I -c '
import json, sys
conf, name, ns, version = sys.stdin.read(), sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "apiVersion": "zen.cpd.ibm.com/v1", "kind": "ZenExtension",
    "metadata": {"name": name, "namespace": ns,
                 "labels": {"app.kubernetes.io/managed-by": "ibm-software-installation-scripts",
                            "cluster-fixes.ibm-install-scripts/fix": name},
                 "annotations": {"cluster-fixes.ibm-install-scripts/version": version}},
    "spec": {"extensions": json.dumps([{"extension_point_id": "zen_front_door", "extension_name": name,
                                         "details": {"location_conf": "nginx.conf"}}], indent=2),
             "nginx.conf": conf}}, indent=2))' "${EXT_NAME}" "${NS}" "${VERSION}"
}

if [[ "${PREVIEW}" == "true" ]]; then
    trap - EXIT  # keep stdout pure JSON (pipeable into oc apply -f -)
    render_cr
    exit 0
fi

if [[ -n "${OC_LOGIN:-}" ]]; then
    eval "${OC_LOGIN}" >/dev/null
elif ! oc whoami &>/dev/null; then
    echo "[ERROR] Not logged in. Set OC_LOGIN in cpd_vars.sh or run oc login first." >&2
    exit 1
fi
echo "[INFO] Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown), namespace ${NS}, autoheal version ${VERSION}"

CPD_HOST=$(oc -n "${NS}" get route cpd -o jsonpath='{.spec.host}' 2>/dev/null || true)
[[ -z "${CPD_HOST}" ]] && { echo "[ERROR] Route 'cpd' not found in ${NS}" >&2; exit 1; }

nginx_pods() { oc -n "${NS}" get pods -l component=ibm-nginx --field-selector=status.phase=Running -o name 2>/dev/null | sed 's|pod/||'; }
tester_pod() { oc -n "${NS}" get pods --field-selector=status.phase=Running -o name 2>/dev/null | grep -m1 'ibm-nginx-tester' | sed 's|pod/||'; }
cr_exists() { oc -n "${NS}" get zenextension "${EXT_NAME}" &>/dev/null; }

# Served JS version ("" when the endpoint is missing).
served_version() {
    curl -sk -m 15 "https://${CPD_HOST}/cpd-pane-autoheal/autoheal.js" 2>/dev/null \
        | grep -o 'var VERSION = "[^"]*"' | head -1 | cut -d'"' -f2 || true
}

# Is the script tag injected into a real page? /zen/ redirects to the (public) IAM login page.
page_injected() {
    curl -sk -m 20 -L --max-redirs 6 -H 'Sec-Fetch-Dest: document' -H 'Accept: text/html' \
        "https://${CPD_HOST}/zen/" 2>/dev/null | grep -o 'cpd-pane-autoheal/autoheal.js?v=[^"]*' | head -1 | cut -d= -f2 || true
}

# nginx -t of the live config plus the snippet, on a copy inside ibm-nginx-tester.
validate() {
    local pod; pod=$(tester_pod)
    [[ -z "${pod}" ]] && pod=$(nginx_pods | head -1)
    [[ -z "${pod}" ]] && { echo "[ERROR] No ibm-nginx(-tester) pod running" >&2; return 1; }
    echo "[INFO] Dry run: nginx -t with the snippet in ${pod} (copy under ${VALIDATE_DIR}, live config untouched)"
    render_snippet | oc -n "${NS}" exec -i "${pod}" -c "$(oc -n "${NS}" get pod "${pod}" -o jsonpath='{.spec.containers[0].name}')" -- sh -c '
        set -e; D='"${VALIDATE_DIR}"'
        rm -rf "$D"; mkdir -p "$D"; cat > "$D/snippet.conf"
        C=$(nginx -V 2>&1 | sed -n "s/.*--conf-path=\([^ ]*\).*/\1/p"); C=${C:-/usr/local/openresty/nginx/conf/nginx.conf}
        sed "s#include /nginx_data/extensions/locations/\*.conf;#&\n include $D/snippet.conf;#" /nginx_data/defaults.d/external-server.conf > "$D/external-server.conf"
        grep -q "$D/snippet.conf" "$D/external-server.conf" || { echo "include point not found in external-server.conf"; exit 3; }
        sed -e "s#include /nginx_data/defaults.d/external-server.conf;#include $D/external-server.conf;#" \
            -e "s#include mime.types;#include $(dirname "$C")/mime.types;#" "$C" > "$D/nginx.conf"
        rc=0; nginx -t -c "$D/nginx.conf" 2>&1 | grep -v "\[warn\]" || true
        nginx -t -c "$D/nginx.conf" >/dev/null 2>&1 || rc=$?
        rm -rf "$D"; exit $rc'
}

wait_for() {  # wait_for <description> <command...>
    local what="$1"; shift
    local start=${SECONDS}
    while (( SECONDS - start < TIMEOUT )); do
        if "$@"; then echo "[INFO] ${what}: done after $((SECONDS - start))s"; return 0; fi
        echo "[INFO] ${what}: waiting ($((SECONDS - start))s / ${TIMEOUT}s)"
        sleep 15
    done
    echo "[ERROR] ${what}: not reached within ${TIMEOUT}s" >&2
    return 1
}

cr_state() {
    oc -n "${NS}" get zenextension "${EXT_NAME}" -o jsonpath='{.status.zenExtensionStatus}{" | "}{.status.message}{" | applied-version="}{.metadata.annotations.cluster-fixes\.ibm-install-scripts/version}' 2>/dev/null || true
}

is_live()     { [[ "$(served_version)" == "${VERSION}" ]]; }
cr_failed()   { [[ "$(oc -n "${NS}" get zenextension "${EXT_NAME}" -o jsonpath='{.status.zenExtensionStatus}' 2>/dev/null)" == "Failed" ]]; }
live_or_failed() { is_live || cr_failed; }
is_gone()     { ! cr_exists && [[ -z "$(served_version)" ]]; }

do_status() {
    echo "== ZenExtension ${NS}/${EXT_NAME}"
    if cr_exists; then echo "  present: $(cr_state)"; else echo "  absent"; fi
    echo "== ibm-nginx pods carrying the snippet"
    local pods total=0 with=0 p
    pods=(${(f)"$(nginx_pods)"})
    for p in "${pods[@]}"; do
        total=$((total + 1))
        if oc -n "${NS}" exec "${p}" -c ibm-nginx-container -- sh -c 'grep -lq "cpd-pane-autoheal" /nginx_data/extensions/locations/*.conf' &>/dev/null; then
            with=$((with + 1))
        fi
        echo "  checked ${total}/${#pods[@]}"
    done
    echo "  ${with}/${total} pods"
    local sv pv; sv=$(served_version); pv=$(page_injected)
    echo "== JS endpoint   https://${CPD_HOST}/cpd-pane-autoheal/autoheal.js -> ${sv:-not served}"
    echo "== Page injection (IAM login page via /zen/) -> ${pv:-no script tag}"
    echo "== Beacons in ibm-nginx logs (last ${SINCE})"
    local logs=""
    for p in "${pods[@]}"; do
        logs+=$(oc -n "${NS}" logs "${p}" -c ibm-nginx-container --since="${SINCE}" 2>/dev/null | grep '\[cpd-pane-autoheal\]' || true)$'\n'
    done
    local n; n=$(print -r -- "${logs}" | grep -c 'cpd-pane-autoheal' || true)
    if (( n == 0 )); then
        echo "  none"
    else
        print -r -- "${logs}" | grep -o '"event":"[a-z_]*"' | sort | uniq -c | sed 's/^/  /'
        echo "  latest:"
        print -r -- "${logs}" | grep 'cpd-pane-autoheal' | tail -3 | sed -E 's/.*\[cpd-pane-autoheal\] //' | cut -c1-400 | sed 's/^/    /'
    fi
    if cr_exists && [[ "${sv}" == "${VERSION}" ]]; then STATE=on
    elif cr_exists; then STATE="on (pending/outdated: served '${sv:-none}', repo ${VERSION})"
    elif [[ -n "${sv}" ]]; then STATE="off (endpoint still served by some pod)"
    else STATE=off; fi
    echo "== STATE: ${STATE}"
}

do_on() {
    validate || { echo "[ERROR] nginx -t dry run failed; nothing applied" >&2; exit 1; }
    echo "[INFO] Applying ZenExtension ${EXT_NAME}"
    render_cr | oc apply -f -
    wait_for "ibm-nginx serving autoheal ${VERSION}" live_or_failed || exit 1
    if cr_failed; then
        echo "[ERROR] zen rejected the extension: $(cr_state)" >&2
        echo "[ERROR] Remove it with --action=off" >&2
        exit 1
    fi
    local pv; pv=$(page_injected)
    if [[ "${pv}" == "${VERSION}" ]]; then
        echo "[INFO] Verified: JS served and injected into pages (v=${pv})"
    else
        echo "[WARN] JS is served but the probe page shows no script tag (got '${pv}'); check with --action=status" >&2
    fi
    echo "[INFO] Per-browser opt-out: localStorage.setItem('cpdPaneAutoheal','off')"
}

do_off() {
    if cr_exists; then
        echo "[INFO] Deleting ZenExtension ${EXT_NAME}"
        oc -n "${NS}" delete zenextension "${EXT_NAME}" --wait=false
    else
        echo "[INFO] ZenExtension ${EXT_NAME} not present"
    fi
    wait_for "autoheal removed from ibm-nginx" is_gone || exit 1
    echo "[INFO] Pages already open keep the script until reloaded; it is inert without the endpoint."
}

case "${ACTION}" in
    status)   do_status ;;
    validate) validate && echo "[INFO] nginx -t dry run passed" ;;
    on)       do_on ;;
    off)      do_off ;;
    toggle)
        if cr_exists; then echo "[INFO] Currently on -> turning off"; do_off
        else echo "[INFO] Currently off -> turning on"; do_on; fi ;;
esac
