#!/bin/zsh
# =============================================================================
# resolve_cpd_cli_release.sh - map an IBM Software Hub version to a cpd-cli release
# -----------------------------------------------------------------------------
# Sourceable helper shared by:
#   - src/scripts/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh  (fresh install)
#   - src/utils/cpd-cli_upgrade_to_version.sh                      (upgrade in place)
#
# Why this exists:
#   The cpd-cli binary is version-locked to an IBM Software Hub release and
#   launches its olm-utils container from that built-in version, ignoring
#   ${OLM_UTILS_IMAGE}. Both installing and upgrading therefore need the same
#   question answered: "which cpd-cli release goes with SWH ${VERSION}?"
#
# The release metadata is shaped like this:
#   name  "v14.4.0.7 IBM Software Hub command line interface 5.4.0 - Patch 7"
#   tag   "v14.4.0.7"                    <- cpd-cli version + its own patch
#   asset "cpd-cli-darwin-EE-14.4.0.tgz" <- patch dropped from the filename
#
#   So the SWH version lives only in the NAME, and the download URL must come
#   from the asset list rather than a rebuilt filename.
#
# Patch numbers:
#   ${PATCH_ID} is the olm-utils/CASE patch and does NOT track cpd-cli patch
#   numbers (SWH 5.4.0 ships cpd-cli patches 0, 3, 5, 7 - there is no 6).
#   Callers match on the SWH version only and take the newest cpd-cli release,
#   which is the backward-compatible choice within a SWH release.
#
# Usage:
#   source "<repo>/src/helpers/resolve_cpd_cli_release.sh"
#   cpd_cli_platform_asset            # -> echoes darwin|linux|arm64|ppc64le|s390x
#   cpd_cli_resolve_release <swh> <platform> <edition> [pin_patch] [list]
#
#   cpd_cli_resolve_release prints TAB-separated KEY<TAB>VALUE lines:
#     TAG, PATCH, CLI_VERSION, ASSET, URL, OTHERS
#   or, with list=1, repeated AVAILABLE<TAB>tag<TAB>patch<TAB>asset lines.
#
#   Exit codes: 0 ok | 2 no release for that SWH version | 3 pinned patch absent
#               1 network/API failure
# =============================================================================

# Guard against double-sourcing.
[[ -n "${_CPD_CLI_RESOLVER_LOADED:-}" ]] && return 0
_CPD_CLI_RESOLVER_LOADED=1

CPD_CLI_RELEASES_API="https://api.github.com/repos/IBM/cpd-cli/releases?per_page=100"

# Map the running host to the asset infix IBM uses in the release filenames.
cpd_cli_platform_asset() {
    case "$(uname -s)" in
        Darwin) echo "darwin" ;;
        Linux)
            case "$(uname -m)" in
                x86_64)  echo "linux" ;;
                aarch64) echo "arm64" ;;
                ppc64le) echo "ppc64le" ;;
                s390x)   echo "s390x" ;;
                *) echo "[ERROR] Unsupported Linux architecture: $(uname -m)" >&2; return 1 ;;
            esac ;;
        *) echo "[ERROR] Unsupported operating system: $(uname -s)" >&2; return 1 ;;
    esac
}

# cpd_cli_resolve_release <swh_version> <platform> <edition> [pin_patch] [list_only]
cpd_cli_resolve_release() {
    local swh="$1" platform="$2" edition="$3" pin="${4:-}" list_only="${5:-0}"
    local tmp_json rc

    if [[ -z "${swh}" ]]; then
        echo "[ERROR] cpd_cli_resolve_release: no SWH version given." >&2
        return 1
    fi

    tmp_json="$(mktemp -t cpd-cli-releases)" || return 1

    local -a auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    if ! curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
            "${CPD_CLI_RELEASES_API}" -o "${tmp_json}"; then
        echo "[ERROR] Could not reach the GitHub releases API." >&2
        echo "[ERROR] If this is rate limiting, set GITHUB_TOKEN and retry." >&2
        rm -f "${tmp_json}"
        return 1
    fi

    # One python pass, every value in via the environment, so no shell value is
    # ever interpolated into the program text.
    SWH_VERSION="${swh}" \
    ASSET_PLATFORM="${platform}" \
    EDITION="${edition}" \
    PIN_PATCH="${pin}" \
    LIST_ONLY="${list_only}" \
    RELEASES_JSON="${tmp_json}" \
    python3 <<'PYEOF'
import json, os, re, sys

swh = os.environ["SWH_VERSION"]
platform = os.environ["ASSET_PLATFORM"]
edition = os.environ["EDITION"]
pin = os.environ.get("PIN_PATCH", "").strip()
list_only = os.environ.get("LIST_ONLY") == "1"

with open(os.environ["RELEASES_JSON"]) as fh:
    releases = json.load(fh)

# Anchor on the SWH version as a whole token so 5.4.0 never matches 5.4.01,
# and require the "interface <version>" shape the release names all use.
name_re = re.compile(r"interface\s+" + re.escape(swh) + r"(?!\d)")
patch_re = re.compile(r"Patch\s*(\d+)", re.I)
asset_prefix = "cpd-cli-{}-{}-".format(platform, edition)

matches = []
for rel in releases:
    if rel.get("draft"):
        continue
    if not name_re.search(rel.get("name") or ""):
        continue
    m = patch_re.search(rel.get("name") or "")
    patch = int(m.group(1)) if m else 0
    asset = next(
        (a for a in rel.get("assets", []) if a["name"].startswith(asset_prefix)),
        None,
    )
    if asset is None:
        continue
    matches.append((patch, rel["tag_name"], asset["name"], asset["browser_download_url"]))

if not matches:
    sys.stderr.write(
        "No cpd-cli release found for SWH {} with a {}<ver>.tgz asset.\n".format(
            swh, asset_prefix
        )
    )
    sys.exit(2)

matches.sort(key=lambda t: t[0], reverse=True)

if list_only:
    for patch, tag, aname, _ in matches:
        print("AVAILABLE\t{}\t{}\t{}".format(tag, patch, aname))
    sys.exit(0)

if pin:
    chosen = next((t for t in matches if str(t[0]) == pin), None)
    if chosen is None:
        sys.stderr.write(
            "No cpd-cli patch {} for SWH {}. Available: {}\n".format(
                pin, swh, ", ".join(str(t[0]) for t in matches)
            )
        )
        sys.exit(3)
else:
    chosen = matches[0]

patch, tag, aname, url = chosen
# cpd-cli version as the binary reports it, e.g. 14.4.0 from asset ...-14.4.0.tgz
cli_ver = aname[len(asset_prefix):].rsplit(".tgz", 1)[0]
print("TAG\t{}".format(tag))
print("PATCH\t{}".format(patch))
print("CLI_VERSION\t{}".format(cli_ver))
print("ASSET\t{}".format(aname))
print("URL\t{}".format(url))
print("OTHERS\t{}".format(", ".join(str(t[0]) for t in matches)))
PYEOF
    rc=$?
    rm -f "${tmp_json}"
    return ${rc}
}

# Pull a single KEY's value out of cpd_cli_resolve_release output.
# Usage: cpd_cli_field "${resolved}" TAG
cpd_cli_field() {
    echo "$1" | awk -F'\t' -v k="$2" '$1==k { print $2; exit }'
}
