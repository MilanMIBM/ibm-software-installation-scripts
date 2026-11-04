#!/bin/zsh
# Shared by the scripts in src/utilities/kubecost_utils/. Source it after the
# env_bootstrap line; it runs nothing itself:
#     source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

KC_RESOURCE="kubecosts.charts.kubecost.com"

# Prints the product key from a file ('-' = stdin): either {"key": "..."} (the
# productkey.json format) or the bare key. Whitespace is dropped.
kc_read_key_file() {   # <path|->
    local content key
    if [[ "$1" == "-" ]]; then
        content="$(cat)"
    else
        [[ -r "$1" ]] || { echo "[ERROR] Cannot read key file '$1'." >&2; return 1; }
        content="$(<"$1")"
    fi
    if key="$(jq -er 'if type == "object" then .key | strings else empty end' <<<"${content}" 2>/dev/null)"; then
        :
    elif jq -e 'type == "object"' <<<"${content}" >/dev/null 2>&1; then
        echo "[ERROR] Key file '$1' is JSON but has no string 'key' field." >&2
        return 1
    else
        key="${content}"
    fi
    print -r -- "${key//[[:space:]]/}"
}

# Prints the namespace of the Kubecost instance <name>; fails (listing the
# instances) when there is none or more than one.
kc_find_instance_namespace() {   # <name>
    local -a found
    found=("${(@f)$(oc get "${KC_RESOURCE}" -A -o json \
        | jq -r --arg n "$1" '.items[] | select(.metadata.name == $n) | .metadata.namespace')}")
    found=(${found:#})
    case ${#found[@]} in
        0)  echo "[ERROR] No Kubecost instance named '$1'. Instances on the cluster:" >&2
            oc get "${KC_RESOURCE}" -A 2>&1 | sed 's/^/  /' >&2
            return 1 ;;
        1)  print -r -- "${found[1]}" ;;
        *)  echo "[ERROR] Kubecost instances named '$1' in: ${found[*]}. Pass -n <namespace>." >&2
            return 1 ;;
    esac
}

KC_VARS_FILE="configs/kubecost_config/kubecost_vars.sh"

# Fills the caller's CR_NAME and NAMESPACE with the Kubecost instance to work
# on. Call it after ocu_login. It tries, in this order:
#   1. the instance named on the command line (-n, else the namespace that holds it)
#   2. KUBECOST_INSTANCE_NAME from kubecost_vars.sh, in -n, else
#      KUBECOST_OPERATOR_NAMESPACE, else wherever it is on the cluster
#   3. the only instance on the cluster (in -n when given)
# When there are several instances, it asks which one on a terminal and fails
# (listing them) otherwise.
kc_resolve_instance() {
    local ns line i=0 choice
    local -a found
    if [[ -n "${CR_NAME}" ]]; then
        [[ -n "${NAMESPACE}" ]] || NAMESPACE="$(kc_find_instance_namespace "${CR_NAME}")" || return 1
        return 0
    fi

    if [[ -n "${KUBECOST_INSTANCE_NAME:-}" ]]; then
        ns="${NAMESPACE:-${KUBECOST_OPERATOR_NAMESPACE:-}}"
        if [[ -n "${ns}" ]] && oc get "${KC_RESOURCE}" "${KUBECOST_INSTANCE_NAME}" -n "${ns}" &>/dev/null; then
            :
        elif [[ -z "${NAMESPACE}" ]] && ns="$(kc_find_instance_namespace "${KUBECOST_INSTANCE_NAME}" 2>/dev/null)"; then
            :
        else
            ns=""
            echo "[WARN] KUBECOST_INSTANCE_NAME='${KUBECOST_INSTANCE_NAME}' (${KC_VARS_FILE}) is not on the cluster${NAMESPACE:+ in '${NAMESPACE}'}; looking for other instances." >&2
        fi
        if [[ -n "${ns}" ]]; then
            CR_NAME="${KUBECOST_INSTANCE_NAME}"; NAMESPACE="${ns}"
            echo "[INFO] No instance named; using KUBECOST_INSTANCE_NAME from ${KC_VARS_FILE}: ${NAMESPACE}/${CR_NAME}"
            return 0
        fi
    fi

    local -a scope=(-A)
    [[ -n "${NAMESPACE}" ]] && scope=(-n "${NAMESPACE}")
    found=("${(@f)$(oc get "${KC_RESOURCE}" "${scope[@]}" -o json \
        | jq -r '.items[] | "\(.metadata.namespace)\t\(.metadata.name)"')}")
    found=(${found:#})
    case ${#found[@]} in
        0)  echo "[ERROR] No Kubecost instance on the cluster${NAMESPACE:+ in '${NAMESPACE}'}. Install one with install_kubecost_operator.sh." >&2
            return 1 ;;
        1)  NAMESPACE="${found[1]%%$'\t'*}"; CR_NAME="${found[1]#*$'\t'}"
            echo "[INFO] No instance named; using the only Kubecost instance on the cluster: ${NAMESPACE}/${CR_NAME}"
            return 0 ;;
    esac
    if [[ -t 0 && -t 2 ]]; then
        echo "Kubecost instances on the cluster${NAMESPACE:+ in '${NAMESPACE}'}:" >&2
        for line in "${found[@]}"; do
            printf '  %d) %s/%s\n' $(( ++i )) "${line%%$'\t'*}" "${line#*$'\t'}" >&2
        done
        while true; do
            printf 'Which one [1-%d]: ' ${#found[@]} >&2
            read -r choice || return 1
            [[ "${choice}" == <-> ]] && (( choice >= 1 && choice <= ${#found[@]} )) && break
        done
        NAMESPACE="${found[choice]%%$'\t'*}"; CR_NAME="${found[choice]#*$'\t'}"
        return 0
    fi
    echo "[ERROR] Several Kubecost instances${NAMESPACE:+ in '${NAMESPACE}'}; name one (and -n <namespace> if the name repeats), or set KUBECOST_INSTANCE_NAME in ${KC_VARS_FILE}:" >&2
    for line in "${found[@]}"; do echo "  ${line%%$'\t'*}/${line#*$'\t'}" >&2; done
    return 1
}

# Highest Helm release revision of the instance (0 if none). The operator
# installs each instance as a Helm release named after the CR.
kc_release_revision() {   # <name> <namespace>
    oc get secret -n "$2" -l "owner=helm,name=$1" \
        -o jsonpath='{range .items[*]}{.metadata.labels.version}{"\n"}{end}' 2>/dev/null \
        | sort -n | tail -1 | grep . || echo 0
}

# Waits until the operator has applied a CR change: a release revision newer
# than <start revision> is deployed. Fails on a failed revision or a
# ReleaseFailed/Irreconcilable condition set after <start time> (a template
# error leaves no revision), and on timeout. Prints progress as it goes.
kc_wait_for_release() {   # <name> <namespace> <start revision> <start time, ISO UTC> <timeout s>
    local name="$1" ns="$2" start_rev="$3" start_ts="$4" timeout="$5"
    local rev rev_status failed_msg line last="" started=${SECONDS}
    echo "[INFO] Waiting for the operator to roll out the change (up to ${timeout}s)..."
    while (( SECONDS - started < timeout )); do
        rev="$(kc_release_revision "${name}" "${ns}")"
        rev_status="$(oc get secret -n "${ns}" "sh.helm.release.v1.${name}.v${rev}" \
            -o jsonpath='{.metadata.labels.status}' 2>/dev/null || true)"
        failed_msg="$(oc get "${KC_RESOURCE}" "${name}" -n "${ns}" -o json | jq -r --arg t "${start_ts}" '
            [.status.conditions[]? | select((.type == "ReleaseFailed" or .type == "Irreconcilable")
              and .status == "True" and .lastTransitionTime >= $t) | .message] | first // ""')"
        line="release revision ${rev} (${rev_status:-?})"
        if [[ "${line}" != "${last}" ]]; then
            echo "  [$(( SECONDS - started ))s/${timeout}s] ${line}"
            last="${line}"
        fi
        if [[ -n "${failed_msg}" ]]; then
            echo "[ERROR] The operator could not apply the change: ${failed_msg}" >&2
            return 1
        fi
        if (( rev > start_rev )); then
            case "${rev_status}" in
                deployed) echo "[OK] Release revision ${rev} deployed."; return 0 ;;
                failed)   echo "[ERROR] Release revision ${rev} failed. See: oc get ${KC_RESOURCE} ${name} -n ${ns} -o yaml" >&2
                          return 1 ;;
            esac
        fi
        sleep 5
    done
    echo "[ERROR] The operator did not finish within ${timeout}s. Check: oc get ${KC_RESOURCE} ${name} -n ${ns} -o yaml" >&2
    return 1
}

# =============================================================================
# Local config: configs/kubecost_config/<namespace>/ (gitignored, 0700/0600)
#   <instance>-instance_details.sh   login URL, mode, credentials (sourceable)
#   <secret>-productkey.json         copy of a product key Secret's productkey.json
#   <instance>-management-postgres.json  Postgres integration connection + queries
#   <instance>-features.yaml         optional features (generate/apply_kubecost_features)
# =============================================================================
KC_CONFIG_DIR="${_CP4D_REPO_ROOT}/configs/kubecost_config"

_kc_private_dir() {   # <dir>
    (umask 077; mkdir -p "$1")
    chmod 700 "${KC_CONFIG_DIR}" "$1"
}

_kc_write_private() {   # <file>; content on stdin, written atomically
    local tmp="$1.tmp.$$"
    _kc_private_dir "${1:h}"
    (umask 077; cat > "${tmp}")
    chmod 600 "${tmp}"
    mv -f "${tmp}" "$1"
}

# The chart's kubecost.fullname helper (names the Route <fullname>-route).
kc_fullname() {   # <cr json> <cr name>
    jq -r --arg r "$2" '
        .spec.fullnameOverride // (
            (.spec.nameOverride // "kubecost") as $n
            | if ($r | contains($n)) then $r else "\($r)-\($n)" end)
        | .[:63] | rtrimstr("-")' <<<"$1"
}

kc_key_from_secret() {   # <namespace> <secret>  -> key, or nothing
    oc get secret "$2" -n "$1" -o json 2>/dev/null \
        | jq -r '.data["productkey.json"] // empty | @base64d | fromjson? | .key // empty' || true
}

kc_product_key_file() {   # <namespace> <name>  -> REPLY = path
    REPLY="${KC_CONFIG_DIR}/$1/$2-productkey.json"
}

# Saves <key> as configs/kubecost_config/<ns>/<name>-productkey.json. An
# existing file with another key is only overwritten with <force>=true;
# otherwise the difference is reported and the file kept.
kc_save_product_key_file() {   # <namespace> <name> <key> <force: true|false>
    local f old
    kc_product_key_file "$1" "$2"; f="${REPLY}"
    if [[ -f "${f}" ]]; then
        old="$(kc_read_key_file "${f}" 2>/dev/null || true)"
        [[ "${old}" == "$3" ]] && return 0
        if [[ "$4" != true ]]; then
            echo "[WARN] ${f#${_CP4D_REPO_ROOT}/} holds another key (${old[1,4]}****) than the cluster (${3[1,4]}****); kept as is."
            echo "[WARN]   use the file's key:     product_key/link_kubecost_product_key.sh <instance> -f ${f#${_CP4D_REPO_ROOT}/}"
            echo "[WARN]   take the cluster's key: instance_details/get_kubecost_instance_details.sh <instance> --update-key-file"
            return 0
        fi
    fi
    jq -n --arg k "$3" '{key: $k}' | _kc_write_private "${f}"
    echo "[OK] Product key saved to ${f#${_CP4D_REPO_ROOT}/}"
}

# How a product key reaches the instance. Sets KC_KEY_LINKED (true/false),
# KC_KEY_SOURCE (text), KC_KEY_SECRET (Secret name when a Secret is used) and
# KC_KEY_VALUE (the key, when readable).
kc_product_key_status() {   # <cr json> <namespace>
    local pk secret
    KC_KEY_LINKED=false; KC_KEY_SOURCE="none"; KC_KEY_SECRET=""; KC_KEY_VALUE=""
    pk="$(jq -c '.spec.kubecostProductConfigs.productKey // {}' <<<"$1")"
    [[ "$(jq -r '.enabled // false' <<<"${pk}")" == true ]] || return 0
    if [[ -n "$(jq -r '.key // ""' <<<"${pk}")" ]]; then
        KC_KEY_LINKED=true; KC_KEY_SOURCE="inline key in the CR"
        KC_KEY_VALUE="$(jq -r '.key' <<<"${pk}")"
    elif [[ -n "$(jq -r '.mountPath // ""' <<<"${pk}")" ]]; then
        KC_KEY_LINKED=true; KC_KEY_SOURCE="mounted file $(jq -r '.mountPath' <<<"${pk}")"
    else
        # Chart default Secret name: product-key.
        secret="$(jq -r '.secretname // "" | if . == "" then "product-key" else . end' <<<"${pk}")"
        if oc get secret "${secret}" -n "$2" &>/dev/null; then
            KC_KEY_LINKED=true; KC_KEY_SOURCE="Secret ${secret}"; KC_KEY_SECRET="${secret}"
            KC_KEY_VALUE="$(kc_key_from_secret "$2" "${secret}")"
        else
            KC_KEY_SOURCE="productKey enabled, but Secret ${secret} is missing"
        fi
    fi
}

# Users and groups bound to the cluster-admin ClusterRole, without system:
# ones and service accounts. Members of bound OpenShift Groups are added to
# the users. Sets KC_ADMIN_USERS and KC_ADMIN_GROUPS (arrays).
kc_cluster_admins() {
    local kind name
    KC_ADMIN_USERS=(); KC_ADMIN_GROUPS=()
    while IFS=$'\t' read -r kind name; do
        [[ -n "${name}" ]] || continue
        if [[ "${kind}" == User ]]; then
            KC_ADMIN_USERS+=("${name}")
        else
            KC_ADMIN_GROUPS+=("${name}")
            KC_ADMIN_USERS+=("${(@f)$(oc get group "${name}" -o jsonpath='{range .users[*]}{@}{"\n"}{end}' 2>/dev/null || true)}")
        fi
    done < <(oc get clusterrolebindings -o json | jq -r '
        .items[] | select(.roleRef.kind == "ClusterRole" and .roleRef.name == "cluster-admin")
        | .subjects[]? | select(.kind == "User" or .kind == "Group")
        | select(.name | startswith("system:") | not) | "\(.kind)\t\(.name)"' | sort -u)
    KC_ADMIN_USERS=(${(u)KC_ADMIN_USERS:#})
}

# Reads the instance's UI, login and key settings from the cluster and writes
# configs/kubecost_config/<ns>/<instance>-instance_details.sh (variables
# KUBECOST_*). Also saves the product key file when the key is in
# a Secret (<update key file>=true overwrites a different local key).
# REPLY = details file path.
kc_save_instance_details() {   # <instance> <namespace> <update key file: true|false>
    local cr="$1" ns="$2" cr_json fullname host="" url="" mode sar="" p
    local oidc_secret="" oidc_secret_value="" master_key="" key_file=""
    local -a vars
    cr_json="$(oc get "${KC_RESOURCE}" "${cr}" -n "${ns}" -o json)" || return 1
    fullname="$(kc_fullname "${cr_json}" "${cr}")"
    host="$(oc get route "${fullname}-route" -n "${ns}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && url="https://${host}"

    if [[ "$(jq -r '.spec.frontend.enabled // true' <<<"${cr_json}")" == false ]]; then
        mode="ui-disabled"
    elif [[ "$(jq -r '.spec.oidc.enabled // false' <<<"${cr_json}")" == true ]]; then
        mode="oidc"
    elif [[ "$(jq -r '.spec.saml.enabled // false' <<<"${cr_json}")" == true ]]; then
        mode="saml"
    elif jq -e '[.spec.extraObjects // [] | .[] | select((.metadata.labels // {})["kubecost-ui-login/managed"] == "true")] | length > 0' \
            <<<"${cr_json}" >/dev/null; then
        mode="openshift"
        sar="$(jq -r '.spec.extraObjects[] | select(.kind == "Deployment") | .spec.template.spec.containers[]
            | .args[]? | select(startswith("--openshift-sar=")) | ltrimstr("--openshift-sar=")' <<<"${cr_json}" | head -1)"
    elif [[ -n "${host}" ]]; then
        mode="none"   # published without a login
    else
        mode="not-published"
    fi

    p="KUBECOST_"   # the file name says which instance
    vars=("${p}NAME=${cr}" "${p}NAMESPACE=${ns}" "${p}URL=${url}" "${p}LOGIN_MODE=${mode}")
    case "${mode}" in
        openshift)
            vars+=("${p}LOGIN=OpenShift login (your cluster user)"
                   "${p}OPENSHIFT_ACCESS_CHECK=${sar:-any cluster user}")
            kc_cluster_admins
            vars+=("${p}ADMIN_USERS=${(j:,:)KC_ADMIN_USERS}" "${p}ADMIN_GROUPS=${(j:,:)KC_ADMIN_GROUPS}") ;;
        oidc)
            oidc_secret="$(jq -r 'if .spec.oidc.existingCustomSecret.enabled then .spec.oidc.existingCustomSecret.name
                                  else .spec.oidc.secretName // "kubecost-oidc-secret" end' <<<"${cr_json}")"
            oidc_secret_value="$(oc get secret "${oidc_secret}" -n "${ns}" -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
            vars+=("${p}LOGIN=OIDC"
                   "${p}OIDC_DISCOVERY_URL=$(jq -r '.spec.oidc.discoveryURL // ""' <<<"${cr_json}")"
                   "${p}OIDC_CLIENT_ID=$(jq -r '.spec.oidc.clientID // ""' <<<"${cr_json}")"
                   "${p}OIDC_CLIENT_SECRET_NAME=${oidc_secret}"
                   "${p}OIDC_CLIENT_SECRET=${oidc_secret_value}"
                   "${p}OIDC_REDIRECT_URI=$(jq -r '.spec.oidc.loginRedirectURL // ""' <<<"${cr_json}")"
                   "${p}ADMIN_MATCH=$(jq -r '[.spec.oidc.rbac.groups[]? | select(.name == "admin" and .enabled)
                        | "\(.claimName)=\(.claimValues | join("|"))"] | join(" ; ")' <<<"${cr_json}")") ;;
        saml)
            vars+=("${p}LOGIN=SAML"
                   "${p}SAML_IDP_METADATA_URL=$(jq -r '.spec.saml.idpMetadataURL // ""' <<<"${cr_json}")"
                   "${p}SAML_METADATA_SECRET=$(jq -r '.spec.saml.metadataSecretName // ""' <<<"${cr_json}")"
                   "${p}SAML_ACS_URL=${url:+${url}/saml/acs}"
                   "${p}SAML_AUDIENCE=$(jq -r '.spec.saml.audienceURI // ""' <<<"${cr_json}")"
                   "${p}ADMIN_MATCH=$(jq -r '[.spec.saml.rbac.groups[]? | select(.name == "admin" and .enabled)
                        | "\(.assertionName)=\(.assertionValues | join("|"))"] | join(" ; ")' <<<"${cr_json}")") ;;
        none)
            vars+=("${p}LOGIN=none: anyone who reaches the URL gets in") ;;
        not-published)
            vars+=("${p}LOGIN=no Route; oc port-forward svc/${cr}-frontend 9090 -n ${ns}") ;;
    esac
    master_key="$(oc get secret kubecost-master-api-key -n "${ns}" -o jsonpath='{.data.master-api-key}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "${master_key}" ]] && vars+=("${p}API_MASTER_KEY=${master_key//[[:space:]]/}")

    kc_product_key_status "${cr_json}" "${ns}"
    if [[ -n "${KC_KEY_VALUE}" ]]; then
        if [[ -n "${KC_KEY_SECRET}" ]]; then
            kc_save_product_key_file "${ns}" "${KC_KEY_SECRET}" "${KC_KEY_VALUE}" "$3"
            kc_product_key_file "${ns}" "${KC_KEY_SECRET}"
        else
            kc_save_product_key_file "${ns}" "${cr}-inline" "${KC_KEY_VALUE}" "$3"
            kc_product_key_file "${ns}" "${cr}-inline"
        fi
        key_file="${REPLY}"
    fi
    vars+=("${p}PRODUCT_KEY_SOURCE=${KC_KEY_SOURCE}" "${p}PRODUCT_KEY_SECRET=${KC_KEY_SECRET}"
           "${p}PRODUCT_KEY=${KC_KEY_VALUE}" "${p}PRODUCT_KEY_FILE=${key_file}")
    vars+=("${p}CURRENCY=$(jq -r '.spec.kubecostProductConfigs.currencyCode // "USD"' <<<"${cr_json}")")
    vars+=("${p}CSV_PRICING=$(jq -r '.spec.enterpriseCustomPricing // {} | if .enabled then
                "enabled (ConfigMap \(.configMapName // "" | if . == "" then "none: set in the UI" else . end))" else "off" end' <<<"${cr_json}")"
           "${p}CUSTOM_PRICES=$(jq -r '.spec.finopsagent.agent.kubecost.customPrices // {} | if .enabled then
                ([to_entries[] | select(.key != "enabled" and (.value | tostring) != "") | "\(.key)=\(.value)"] | join(" ")) else "off" end' <<<"${cr_json}")")

    kc_postgres_status "${cr_json}" "${ns}"
    if [[ "${KC_PG_ENABLED}" == true ]]; then
        kc_postgres_file "${ns}" "${cr}"
        vars+=("${p}POSTGRES=enabled (every ${KC_PG_INTERVAL}, ${KC_PG_QUERIES} queries)"
               "${p}POSTGRES_SECRET=${KC_PG_SECRET}"
               "${p}POSTGRES_HOST=$(jq -r '.host' <<<"${KC_PG}")"
               "${p}POSTGRES_PORT=$(jq -r '.port' <<<"${KC_PG}")"
               "${p}POSTGRES_DATABASE=$(jq -r '.databaseName' <<<"${KC_PG}")"
               "${p}POSTGRES_USER=$(jq -r '.user' <<<"${KC_PG}")"
               "${p}POSTGRES_PASSWORD=$(jq -r '.password' <<<"${KC_PG}")"
               "${p}POSTGRES_FILE=$([[ -f "${REPLY}" ]] && print -r -- "${REPLY}")")
    else
        vars+=("${p}POSTGRES=off")
    fi

    local f="${KC_CONFIG_DIR}/${ns}/${cr}-instance_details.sh" kv
    {
        print -r -- "# Kubecost instance ${cr} in ${ns}, cluster $(oc whoami --show-server 2>/dev/null || echo '?'), written by ${ZSH_ARGZERO:t} on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "${vars[@]}"; do
            print -r -- "export ${kv%%=*}=${(qq)${kv#*=}}"
        done
    } | _kc_write_private "${f}"
    REPLY="${f}"
}

# =============================================================================
# Pricing
# =============================================================================
# Node label that groups nodes with an identical resource profile, for CSV
# pricing rows that match on a label (nodes without an instance-type label,
# e.g. bare metal, or instance types that don't map to a single profile).
KC_PROFILE_LABEL="kubecost.pricing/profile"

# JSON array, one entry per node: node, role (master/infra/worker), cores,
# memGiB (rounded), gpus, gpuProduct, arch, instanceType, region,
# currentProfile (the label now on the node) and profile: the resource profile
# ID, e.g. worker-32c-126gib-amd64. Nodes with the same ID are priced alike.
kc_node_profiles() {
    oc get nodes -o json | jq -c --arg label "${KC_PROFILE_LABEL}" '
        def mem_gib:
            if test("Ki$") then (rtrimstr("Ki") | tonumber / 1048576)
            elif test("Mi$") then (rtrimstr("Mi") | tonumber / 1024)
            elif test("Gi$") then (rtrimstr("Gi") | tonumber)
            elif test("^[0-9]+$") then (tonumber / 1073741824)
            else 0 end;
        def cores: if test("m$") then (rtrimstr("m") | tonumber / 1000) else tonumber end;
        def slug: ascii_downcase | gsub("[^a-z0-9.]+"; "-") | ltrimstr("-") | rtrimstr("-");
        [.items[] | .metadata.labels as $l
         | {node: .metadata.name,
            role: (if $l["node-role.kubernetes.io/master"] != null or $l["node-role.kubernetes.io/control-plane"] != null then "master"
                   elif $l["node-role.kubernetes.io/infra"] != null then "infra" else "worker" end),
            cores: (.status.capacity.cpu | cores),
            memGiB: (.status.capacity.memory | mem_gib | round),
            gpus: ((.status.capacity["nvidia.com/gpu"] // .status.capacity["amd.com/gpu"] // "0") | tonumber),
            gpuProduct: ($l["nvidia.com/gpu.product"] // ""),
            arch: (.status.nodeInfo.architecture // "unknown"),
            instanceType: ($l["node.kubernetes.io/instance-type"] // $l["beta.kubernetes.io/instance-type"] // ""),
            region: ($l["topology.kubernetes.io/region"] // $l["failure-domain.beta.kubernetes.io/region"] // ""),
            currentProfile: ($l[$label] // "")}
         | .profile = (("\(.role)-\(.cores)c-\(.memGiB)gib"
                        + (if .gpus > 0 then "-\(.gpus)x" + ((if .gpuProduct == "" then "gpu" else .gpuProduct end) | slug) else "" end)
                        + "-\(.arch | slug)") | .[:63] | rtrimstr("-"))]'
}

# What the aggregator's CSV pricing (Enterprise Custom Pricing) runs on, from
# its /pricing/status API: {"enabled", "authorized", "source" (helm|ui|...),
# "spec": {"uri", "parsed", "valid"}}. Nothing when it can't be read.
kc_ecp_status() {   # <instance> <namespace>
    oc exec "$1-aggregator-0" -n "$2" -c aggregator -- curl -s -m 10 localhost:9004/pricing/status 2>/dev/null \
        | jq -c '.data // empty' 2>/dev/null || true
}

# =============================================================================
# Postgres integration (global.integrations.postgres, Enterprise)
# =============================================================================
# Local copy of an instance's connection + queries:
#   configs/kubecost_config/<ns>/<instance>-management-postgres.json
kc_postgres_file() {   # <namespace> <instance>  -> REPLY = path
    REPLY="${KC_CONFIG_DIR}/$1/$2-management-postgres.json"
}

# Normalises Postgres connection JSON on stdin to
# {host, port, databaseName, user, password[, runInterval][, queryConfigs]}.
# Takes creds.json, a management-postgres.json, chart values
# (global.integrations.postgres) and the usual key spellings
# (databaseHost, dbname, username, databasePassword, ...).
kc_postgres_normalize() {
    jq -c '(.global.integrations.postgres // .integrations.postgres // .postgres // .) as $p
        | {host: ($p.host // $p.databaseHost // ""),
           port: ($p.port // $p.databasePort // "" | tostring),
           databaseName: ($p.databaseName // $p.dbname // $p.database // ""),
           user: ($p.user // $p.username // $p.databaseUser // ""),
           password: ($p.password // $p.databasePassword // "")}
          + (if ($p.runInterval // "") != "" then {runInterval: ($p.runInterval | tostring)} else {} end)
          + (if $p.queryConfigs then {queryConfigs: $p.queryConfigs} else {} end)'
}

# Connection fields from a Secret: its creds.json key, or flat keys as in
# CloudNativePG/EDB/Crunchy app Secrets (host, port, dbname, user|username,
# password). A short host name from a Secret in another namespace than the
# instance's is qualified with that namespace. Fails if the Secret is missing.
kc_postgres_from_secret() {   # <secret namespace> <secret> <instance namespace>
    local js
    js="$(oc get secret "$2" -n "$1" -o json 2>/dev/null)" || return 1
    jq -c '.data // {} | map_values(@base64d)
           | if has("creds.json") then (.["creds.json"] | fromjson) else . end' <<<"${js}" \
        | kc_postgres_normalize \
        | jq -c --arg ns "$1" --arg ins "$3" '
            if $ns != $ins and .host != "" and .host != "localhost" and (.host | contains(".") | not)
            then .host += ".\($ns).svc" else . end'
}

# The instance's Postgres integration. Sets KC_PG_ENABLED (true/false),
# KC_PG_SECRET (the Secret the aggregator mounts), KC_PG_INTERVAL,
# KC_PG_QUERIES (number of queries) and KC_PG (normalized connection JSON,
# {} when unreadable).
kc_postgres_status() {   # <cr json> <namespace>
    local pg
    pg="$(jq -c '.spec.global.integrations.postgres // {}' <<<"$1")"
    KC_PG_ENABLED="$(jq -r '.enabled // false' <<<"${pg}")"
    # Chart: its own Secret kubecost-integrations-postgres unless databaseSecretName.
    KC_PG_SECRET="$(jq -r '.databaseSecretName // "" | if . == "" then "kubecost-integrations-postgres" else . end' <<<"${pg}")"
    KC_PG_INTERVAL="$(jq -r '.runInterval // "12h"' <<<"${pg}")"
    KC_PG_QUERIES="$(jq -r '[.queryConfigs // {} | .[]? | .[]?] | length' <<<"${pg}")"
    KC_PG="$(kc_postgres_from_secret "$2" "${KC_PG_SECRET}" "$2" 2>/dev/null)" \
        || KC_PG="$(kc_postgres_normalize <<<"${pg}" | jq -c 'del(.runInterval, .queryConfigs)')"
}

# =============================================================================
# Optional features (alerts, budgets, reports, network costs, ...)
# configs/kubecost_config/<ns>/<instance>-features.yaml, converted by
# src/helpers/kubecost_features.py (PyYAML: the repo's .venv)
# =============================================================================
kc_features_file() {   # <namespace> <instance>  -> REPLY = path
    REPLY="${KC_CONFIG_DIR}/$1/$2-features.yaml"
}

# Python with PyYAML (the repo's .venv, else python3 on PATH), running
# <script> from src/helpers/.
kc_py() {   # <script.py> <args...>
    local py="python3" script="$1"; shift
    [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]] && py="${_CP4D_REPO_ROOT}/.venv/bin/python"
    "${py}" -c 'import yaml' 2>/dev/null \
        || { echo "[ERROR] ${py} has no PyYAML; run 'uv sync' in the repo (or pip install pyyaml)." >&2; return 1; }
    "${py}" "${_CP4D_REPO_ROOT}/src/helpers/${script}" "$@"
}

kc_python() { kc_py kubecost_features.py "$@"; }

# Writes the context kubecost_features.py works from to <file> (private): the
# CR spec, the effective Helm values (the chart's helm-values-<instance>
# ConfigMap), Route URL, product key / SSO state, node label counts and the
# decoded data of the Secrets the features use.
kc_features_context() {   # <instance> <namespace> <file>
    local cr="$1" ns="$2" cr_json eff host="" url="" name
    local -a names
    cr_json="$(oc get "${KC_RESOURCE}" "${cr}" -n "${ns}" -o json)" || return 1
    eff="$(oc get configmap "helm-values-${cr}" -n "${ns}" -o json 2>/dev/null \
        | jq -c '.data["user-values.json"] // "{}" | fromjson? // {}' 2>/dev/null)"
    [[ -n "${eff}" ]] || eff='{}'
    host="$(oc get route "$(kc_fullname "${cr_json}" "${cr}")-route" -n "${ns}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && url="https://${host}"
    kc_product_key_status "${cr_json}" "${ns}"

    names=("${cr}-smtp" "${cr}-plugins" "${cr}-federated-storage")
    names+=("${(@f)$(jq -r '.kubecostProductConfigs.smtp.secretname // empty,
        (.plugins.existingCustomSecret // {} | select(.enabled) | .name // empty),
        .global.federatedStorage.existingSecret // empty' <<<"${eff}")}")
    names=(${(u)names:#})
    local secrets='{}' js
    for name in "${names[@]}"; do
        js="$(oc get secret "${name}" -n "${ns}" -o json 2>/dev/null)" || continue
        secrets="$(jq -c --arg n "${name}" --argjson s "${js}" \
            '. + {($n): ($s.data // {} | map_values(try @base64d catch ""))}' <<<"${secrets}")"
    done

    # OpenShift's service CA (every namespace has it; federatedStorage.trustServiceCA)
    local service_ca
    service_ca="$(oc get configmap openshift-service-ca.crt -n "${ns}" \
        -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)"

    oc get nodes -o json | jq -c \
        --arg cr "${cr}" --arg ns "${ns}" --arg url "${url}" --argjson key "${KC_KEY_LINKED}" \
        --arg serviceCA "${service_ca}" \
        --arg refreshInterval "${KUBECOST_REFRESH_INTERVAL:-}" --arg refreshDynamic "${KUBECOST_REFRESH_DYNAMIC:-}" \
        --argjson spec "$(jq -c '.spec // {}' <<<"${cr_json}")" --argjson eff "${eff}" --argjson secrets "${secrets}" '
        ($eff + {}) as $v
        | (if ($v.oidc.enabled // $spec.oidc.enabled // false) then "oidc"
           elif ($v.saml.enabled // $spec.saml.enabled // false) then "saml" else "" end) as $sso
        | {instance: $cr, namespace: $ns, url: $url, keyLinked: $key, sso: $sso,
           ssoRbac: (if $sso == "" then false else ($v[$sso].rbac.enabled // $spec[$sso].rbac.enabled // false) end),
           ssoGroups: (if $sso == "" then false else (($v[$sso].rbac.groups // $spec[$sso].rbac.groups // []) | length > 0) end),
           nodes: (.items | length),
           labelledNodes: ([.items[] | .metadata.labels
               | select(has("topology.kubernetes.io/region") and has("topology.kubernetes.io/zone"))] | length),
           crSpec: $spec, effective: $eff, secrets: $secrets, serviceCA: $serviceCA,
           refreshVars: {interval: $refreshInterval, dynamic: $refreshDynamic}}' | _kc_write_private "$3"
}

# Reports the interval the aggregator really uses after a data refresh change,
# and warns when a fixed one was not taken. Never fails the caller: the change
# itself is done by now.
kc_check_refresh() {   # <instance> <namespace> <timeout s>
    local cr="$1" ns="$2" timeout="$3" env interval dynamic have="" want i
    oc rollout status "statefulset/${cr}-aggregator" -n "${ns}" --timeout="${timeout}s" >/dev/null 2>&1 \
        || { echo "[WARN] The aggregator is not ready yet, so its refresh interval was not checked." >&2; return 0; }
    for i in {1..12}; do
        have="$(oc exec -n "${ns}" "${cr}-aggregator-0" -c aggregator -- curl -s -m 5 http://localhost:9004/debug/orchestrator 2>/dev/null \
            | jq -r '.currentBucketRefreshInterval // empty' 2>/dev/null || true)"
        [[ -n "${have}" ]] && break
        sleep 5
    done
    [[ -n "${have}" ]] || { echo "[WARN] Could not read the aggregator's refresh interval (/debug/orchestrator)." >&2; return 0; }
    env="$(oc get "${KC_RESOURCE}" "${cr}" -n "${ns}" -o json | jq -c '.spec.aggregator.extraEnv // []')"
    interval="$(jq -r 'map(select(.name == "DB_BUCKET_REFRESH_INTERVAL").value) | first // "1h"' <<<"${env}")"
    dynamic="$(jq -r 'map(select(.name == "DYNAMIC_REFRESH_INTERVAL_ENABLED").value) | first // "true"' <<<"${env}")"
    if [[ "${dynamic}" != false ]]; then
        echo "[INFO] The aggregator publishes every ${have}m now (it may change that itself)."
        return 0
    fi
    want=0
    [[ "${interval}" =~ '([0-9]+)h' ]] && want=$(( want + match[1] * 60 ))
    [[ "${interval}" =~ '([0-9]+)m' ]] && want=$(( want + match[1] ))
    if (( have == want )); then
        echo "[OK] The aggregator publishes every ${have}m."
    else
        echo "[WARN] The aggregator publishes every ${have}m, not ${interval}: it did not take the setting. Check its log for 'refresh interval'." >&2
    fi
}

# Restarts the Deployments, StatefulSets and DaemonSets in <namespace> whose
# pods mount <secret> or read it into env (a changed Secret alone does not
# roll them: the chart's config checksums don't cover named Secrets).
kc_restart_secret_consumers() {   # <namespace> <secret> <timeout s>
    local w
    for w in ${(f)"$(oc get deployments,statefulsets,daemonsets -n "$1" -o json | jq -r --arg s "$2" '
        .items[] | select([.spec.template.spec
            | (.volumes[]? | .secret.secretName, (.projected.sources[]? | .secret.name)),
              ((.containers[]?, .initContainers[]?) | (.env[]?.valueFrom.secretKeyRef.name), (.envFrom[]?.secretRef.name))]
          | index($s)) | "\(.kind | ascii_downcase)/\(.metadata.name)"')"}; do
        [[ -n "${w}" ]] || continue
        oc rollout restart "${w}" -n "$1" >/dev/null
        echo "[INFO] Restarted ${w} (Secret $2 changed); waiting..."
        oc rollout status "${w}" -n "$1" --timeout="$3s" 2>&1 | sed 's/^/  /' || return 1
    done
}
