#!/bin/zsh
# =============================================================================
# legacy_version_resolution.sh - the version / channel / image lookups as they
# were before the dynamic resolvers, kept as their fallback
# -----------------------------------------------------------------------------
# Loaded by version_resolver.sh, which tries the new source first (release
# metadata and CASEs, version_catalog.json, PackageManifests, image_tags.py) and
# calls these only when it fails or returns nothing:
#
#     tag="$(vr_try "<what>" <new command...> -- legacy_<name> <args...>)"
#
# The literal values live in legacy_version_resolution.py (LEGACY_PINS); this
# file holds the legacy logic around them. Do not change defaults here: edit
# version_catalog.json, or the resolver.
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _VR_LEGACY_LOADED.
#   - Each function prints its result on stdout and its messages on stderr,
#     exactly as the code it was taken from did.
# =============================================================================

[[ -n "${_VR_LEGACY_LOADED:-}" ]] && return 0
_VR_LEGACY_LOADED=1

# legacy_pin <path> - the literal a script carried for a catalog path or
# channel.<package> (LEGACY_PINS in legacy_version_resolution.py).
legacy_pin() {
    _vr_python "${VR_DIR}/version_catalog.py" legacy "$1"
}

# -----------------------------------------------------------------------------
# 3.3.2_softwarehub_admission_controller.sh: zen-rsi-adm-controller tag
# -----------------------------------------------------------------------------
# Prints case_version of the first "zen:" block in a YAML stream on stdin.
legacy_zen_case_version() {
  awk '
    /^[[:space:]]*zen:[[:space:]]*$/ { match($0, /^[[:space:]]*/); zi = RLENGTH; z = 1; next }
    z && NF {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= zi) exit
      if ($1 == "case_version:") { gsub(/["'\'']/, "", $2); print $2; exit }
    }'
}

# legacy_zen_ac_tag <repo> - the <IMAGE_ARCH> tag of <repo> in the zen CASE that
# patch-<VERSION>-<PATCH_ID>.yaml (or, without a patch, release-<VERSION>.yml in
# the olm-utils container) names.
legacy_zen_ac_tag() {
  local repo="$1" work="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}" zen="" src csv tag
  if [[ -n "${PATCH_ID:-}" ]]; then
    src="${work}/offline/patch/patch-${VERSION}-${PATCH_ID}.yaml"
    [[ -f "${src}" ]] && zen="$(legacy_zen_case_version < "${src}")"
  else
    src="release-${VERSION}.yml in ${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
    zen="$(podman exec "${OLM_UTILS_CONTAINER:-olm-utils-play-v4}" \
      cat "/opt/ansible/ansible-play/config-vars/release-${VERSION}.yml" 2>/dev/null | legacy_zen_case_version || true)"
  fi
  if [[ -z "${zen}" ]]; then
    echo "[ERROR] No zen case_version found in ${src} - run 2.0.2 (case-download) first, or set CPD_CONFIG_AC_IMAGE" >&2
    return 1
  fi

  for csv in "${work}/offline/${VERSION}/.ibm-pak/data/cases/ibm-zen/${zen}/"ibm-zen-${zen}*-images.csv(N); do
    tag="$(awk -F, -v r="${repo}" -v a="${IMAGE_ARCH:-amd64}" \
      '$2 == r && $5 == "IMAGE" && $7 == a { print $3; exit }' "${csv}")"
    [[ -n "${tag}" ]] && break
  done
  if [[ -z "${tag}" ]]; then
    echo "[ERROR] No ${repo} ${IMAGE_ARCH:-amd64} image in the ibm-zen ${zen} CASE (${work}/offline/${VERSION}/.ibm-pak/data/cases/ibm-zen/${zen}) - run 2.0.2 first, or set CPD_CONFIG_AC_IMAGE" >&2
    return 1
  fi
  echo "[INFO] zen CASE ${zen} (from ${src:t}) -> ${repo}:${tag}" >&2
  print -r -- "${tag}"
}

# -----------------------------------------------------------------------------
# Red Hat OpenShift AI channel for a Software Hub release
# -----------------------------------------------------------------------------
# 2.2.3_install_openshift_ai_operator.sh: the fixed map, else the catalog's
# default channel.
legacy_rhoai_channel() {   # <release>
  case "$1" in
    # Software Hub 5.4.0 still pins RHOAI 2.25 (IBM docs, prep-cluster-openshift-ai);
    # the marketplace default is now stable-3.x, which is a major-version jump.
    5.3.0|5.3.1|5.4.0) print -r -- "stable-2.25" ;;
    *)
      echo "[INFO] No fixed RHOAI channel mapping for CP4D VERSION=$1, resolving latest stable from marketplace..." >&2
      oc get packagemanifest rhods-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'
      ;;
  esac
}

# private_registry_mirroring 1_map_content/installs/cpd.sh: the same map, and no
# channel (empty: the catalog's default) for other releases.
legacy_rhoai_channel_offline() {   # <release>
  case "$1" in
    5.3.0|5.3.1|5.4.0) print -r -- "stable-2.25" ;;
    *) print -r -- "" ;;
  esac
}

# -----------------------------------------------------------------------------
# Operator channels the install scripts wrote literally
# -----------------------------------------------------------------------------
# legacy_pkg_channel <package> [preferred] - <preferred> as given (the scripts
# used their configured channel unchecked), else the literal for <package>.
legacy_pkg_channel() {
  if [[ -n "${2:-}" ]]; then
    print -r -- "$2"
  else
    legacy_pin "channel.$1"
  fi
}

# -----------------------------------------------------------------------------
# private_registry_helpers.sh: preg_version_tags before image_tags.py
# -----------------------------------------------------------------------------
legacy_preg_version_tags() {   # <repo> <n> <pattern>
    local repo="$1" n="$2" pat="$3" tmp tags err
    tmp="$(preg_private_tmpdir)"
    preg_write_authfile "${tmp}/auth.json" none --sources
    if ! tags="$(skopeo list-tags --authfile "${tmp}/auth.json" "docker://${repo}" 2>"${tmp}/err")"; then
        err="$(tail -1 "${tmp}/err")"; rm -rf "${tmp}"
        preg_die "Could not list the tags of ${repo} (${err}) - check MIRROR_IBM_ENTITLEMENT_KEY, or list the versions explicitly"
    fi
    rm -rf "${tmp}"
    print -r -- "${tags}" | PAT="${pat}" N="${n}" preg_python -c '
import json, os, re, sys
pat = re.compile(os.environ["PAT"])
found = sorted((tuple(map(int, m.groups())), t) for t in json.load(sys.stdin).get("Tags") or [] for m in [pat.match(t)] if m)
n = int(os.environ["N"])
print(",".join(t for _, t in (found[-n:] if n else found)))'
}
