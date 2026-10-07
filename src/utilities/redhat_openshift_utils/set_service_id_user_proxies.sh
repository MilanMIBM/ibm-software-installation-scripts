        -w '\n%{http_code}' || true)"
    API_CODE="${_resp##*$'\n'}"
    API_BODY="${_resp%$'\n'*}"
}

# IAM reads the prefix from ROKS_USER_PREFIX in the platform-auth-idp configmap,
# which its operator writes from the Authentication CR. The CR is patched, then
# this waits for the configmap and for the IAM pods to restart with it.
IAM_DEPLOYMENTS=(platform-auth-service platform-identity-provider platform-identity-management)
clear_roks_user_prefix() {
    local ns="$1" prefix cr d i
    local -a old_pods
    prefix="$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}' 2>/dev/null || true)"
    if [[ -z "${prefix}" ]]; then
        echo "[INFO] Software Hub: roksUserPrefix is already empty."
        return 0
    elif [[ "${CLEAR_ROKS_USER_PREFIX}" != true ]]; then
        echo "[WARN] Software Hub: roksUserPrefix is '${prefix}', so service IDs can't get a bearer token"
        echo "       or API key with their password. Set CLEAR_ROKS_USER_PREFIX=true to clear it."
        return 0
    fi

    cr="$(oc get authentications.operator.ibm.com -n "${ns}" -o name 2>/dev/null | head -n 1 || true)"
    if [[ -z "${cr}" ]]; then
        echo "[WARN] Software Hub: no IAM Authentication CR in '${ns}', roksUserPrefix ('${prefix}') left as is."
        return 0
    fi
    old_pods=(${(f)"$(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E "/($(IFS='|'; print -r -- "${IAM_DEPLOYMENTS[*]}"))-" || true)"})

    oc patch "${cr}" -n "${ns}" --type=merge -p '{"spec":{"config":{"roksUserPrefix":""}}}' >/dev/null
    echo "[INFO] Software Hub: roksUserPrefix was '${prefix}', cleared on ${cr#*/}. Waiting for IAM (up to ~10 min)..."

    for i in {1..60}; do
        [[ -z "$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}')" ]] && break
        sleep 10
    done
    if [[ -n "$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_USER_PREFIX}')" ]]; then
        echo "[WARN] Software Hub: the IAM operator has not updated platform-auth-idp yet. Check: oc get ${cr} -n ${ns} -o yaml"
        return 0
    fi

    # The operator restarts the pods itself; if it hasn't after 3 minutes, do it here.
    for i in {1..18}; do
        (( ${#old_pods} == 0 )) && break
        oc get "${old_pods[@]}" -n "${ns}" -o name &>/dev/null || break
        sleep 10
    done
    if (( ${#old_pods} > 0 )) && oc get "${old_pods[@]}" -n "${ns}" -o name &>/dev/null; then
        for d in "${IAM_DEPLOYMENTS[@]}"; do
            oc rollout restart "deployment/${d}" -n "${ns}" >/dev/null 2>&1 || true
        done
    fi
    for d in "${IAM_DEPLOYMENTS[@]}"; do
        oc get "deployment/${d}" -n "${ns}" &>/dev/null || continue
        oc rollout status "deployment/${d}" -n "${ns}" --timeout=300s >/dev/null \
            || echo "[WARN] Software Hub: ${d} is not ready yet. Check: oc get pods -n ${ns}"
    done
    echo "[INFO] Software Hub: IAM restarted with an empty roksUserPrefix."
}

register_in_softwarehub() {
    local ns="${SOFTWAREHUB_NAMESPACE}" roks admin _u _body
    local -a found
    if [[ -z "${ns}" ]]; then
        found=(${(f)"$(oc get zenservice -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true)"})
        if (( ${#found} == 0 )); then
            echo "[INFO] No Software Hub instance on this cluster, skipping Software Hub."
            return 0
        elif (( ${#found} > 1 )); then
            echo "[WARN] Several Software Hub instances (${found[*]}). Set SOFTWAREHUB_NAMESPACE; skipping Software Hub."
            return 0
        fi
        ns="${found[1]}"
    fi

    if [[ "$(oc get zenservice -n "${ns}" -o jsonpath='{.items[0].spec.iamIntegration}' 2>/dev/null || true)" != true ]]; then
        echo "[WARN] Software Hub in '${ns}' does not use IAM, so it can't take OpenShift logins. Skipping Software Hub."
        return 0
    fi
    roks="$(oc get configmap platform-auth-idp -n "${ns}" -o jsonpath='{.data.ROKS_ENABLED}' 2>/dev/null || true)"
    if [[ "${roks}" != true ]]; then
        echo "[WARN] Software Hub has OpenShift authentication off (ROKS_ENABLED='${roks}' in ${ns}/platform-auth-idp). Skipping Software Hub."
        return 0
    fi

    clear_roks_user_prefix "${ns}"

    SH_URL="https://$(oc get route cpd -n "${ns}" -o jsonpath='{.spec.host}')"
    admin="$(oc get secret platform-auth-idp-credentials -n "${ns}" -o jsonpath='{.data.admin_username}' | base64 -d)"
    # The password goes in on stdin, so it never shows up in the process list.
    SH_TOKEN="$(oc get secret platform-auth-idp-credentials -n "${ns}" -o jsonpath='{.data.admin_password}' \
        | base64 -d | jq -Rc --arg u "${admin}" '{username: $u, password: .}' \
        | curl -k -s -X POST "${SH_URL}/icp4d-api/v1/authorize" -H "Content-Type: application/json" --data @- \
        | jq -r '.token // empty' 2>/dev/null || true)"
    if [[ -z "${SH_TOKEN}" ]]; then
        echo "[ERROR] Could not sign in to Software Hub at ${SH_URL} as ${admin}." >&2
        SH_FAILED+=("(sign-in)")
        return 0
    fi
    echo "[INFO] Software Hub: ${SH_URL} (namespace ${ns})"

    for _u in "${SERVICE_ID_USERS[@]}"; do
        sh_api GET "/usermgmt/v1/user/$(uri "${_u}")"
        if [[ "${API_CODE}" == 200 ]]; then
            echo "[INFO] Software Hub: '${_u}' already added, roles left as is."
            continue
        elif [[ "${API_CODE}" != 404 ]]; then
            echo "[ERROR] Software Hub: could not look up '${_u}' (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
            continue
        fi
        # Same shape as the records Software Hub creates for OpenShift logins.
        _body="$(jq -cn --arg u "${_u}" \
            '{username: $u, displayName: $u, authenticator: "external", user_roles: $ARGS.positional}
             + (if $u | contains("@") then {email: $u} else {} end)' \
            --args "${SOFTWAREHUB_ROLES[@]}")"
        sh_api POST "/usermgmt/v1/user" "${_body}"
        if [[ "${API_CODE}" == 2* ]]; then
            echo "[INFO] Software Hub: added '${_u}' with ${SOFTWAREHUB_ROLES[*]}."
        else
            echo "[ERROR] Software Hub: adding '${_u}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
        fi
    done

    # A pruned service ID loses its Software Hub account too, so its API key stops working.
    for _u in "${REMOVED[@]}"; do
        sh_api DELETE "/icp4d-api/v1/users/$(uri "${_u}")"
        if [[ "${API_CODE}" == 2* || "${API_CODE}" == 404 ]]; then
            echo "[INFO] Software Hub: removed '${_u}'."
        else
            echo "[ERROR] Software Hub: removing '${_u}' failed (HTTP ${API_CODE}): ${API_BODY}" >&2
            SH_FAILED+=("${_u}")
        fi
    done
}

if [[ "${REGISTER_IN_SOFTWAREHUB}" == true ]]; then
    register_in_softwarehub
fi

# --- Summary --------------------------------------------------------------------
echo "[INFO] ---"
echo "[INFO] '${IDP_NAME}' is not on the login page. Sign in as a service ID with:"
echo "         CLI      oc login $(oc whoami --show-server) -u <user> -p <password>"
echo "         Browser  on the \"Log in with\" page, add &idp=${IDP_URI} to the address"
echo "                  (OpenShift console, or Software Hub > OpenShift authentication)"
echo "         Token    ${TOKEN_LOGIN_URL}&idp=${IDP_URI}"
if [[ -n "${SH_URL}" ]]; then
    echo "[INFO] API keys: run generate_service_id_cpd_apikeys.sh, or sign in at ${SH_URL} as above,"
    echo "                 then Profile and settings > API key > Generate new key."
fi
if (( ${#ISSUED} > 0 )); then
    echo "[INFO] New passwords (also in ${CREDENTIALS_FILE}):"
    for _u in "${ISSUED[@]}"; do
        printf '         %-40s %s\n' "${_u}" "${SAVED_PASSWORDS[${_u}]}"
    done
else
    echo "[INFO] No new passwords issued. Existing ones are in ${CREDENTIALS_FILE}."
fi
echo "[INFO] OpenShift rights, if needed: oc adm policy ... (new accounts start with none)."

if (( ${#SH_FAILED} > 0 )); then
    echo "[ERROR] Software Hub access could not be set for: ${SH_FAILED[*]}" >&2
    exit 1
fi
