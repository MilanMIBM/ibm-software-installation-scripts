#!/bin/sh
# =============================================================================
# 0_initial_check_in.sh - run this first on a new workstation
# -----------------------------------------------------------------------------
# Every other script in this repo is a zsh script that starts with #!/bin/zsh.
# This one has to work before zsh exists, so it is plain POSIX sh: it runs
# unchanged in the sh / bash that ships with macOS and Linux (bash, dash,
# busybox ash) and on Windows in Git Bash, MSYS2, Cygwin or WSL. Nothing needs
# to be installed to run it.
#
#   sh scripts/0_initial_check_in.sh [--yes] [--check]
#
# Checks that zsh is installed and reachable as /bin/zsh (the path in every
# shebang). When it is not, it shows the command that installs zsh with this
# OS's own package manager, so you get the zsh that OS ships, and runs it
# only once you confirm:
#   macOS            Homebrew or MacPorts (macOS itself ships /bin/zsh)
#   Linux / WSL      apt-get, dnf, microdnf, yum, zypper, pacman, apk,
#                    xbps-install, emerge; Homebrew when there is no root
#   Windows MSYS2    pacman
#   Windows Git Bash the MSYS2 zsh package, unpacked into Git for Windows
#   Windows Cygwin   apt-cyg, or Cygwin's setup program
#   BSD              pkg, pkg_add, pkgin
# When zsh is installed somewhere else (FreeBSD's /usr/local/bin, Linuxbrew),
# it offers to link /bin/zsh to it.
#
#   --yes    answer yes to every question (unattended runs)
#   --check  report only, change nothing
#
# Exit status: 0 when /bin/zsh is ready, 1 when it is not.
# =============================================================================

set -u

ASSUME_YES=false
CHECK_ONLY=false

usage() {
    cat <<'EOF'
Check that zsh is installed (as /bin/zsh) and offer to install it.

  sh scripts/0_initial_check_in.sh [--yes] [--check]

  --yes    answer yes to every question (unattended runs)
  --check  report only, change nothing (exit 1 when zsh is not ready)
EOF
}

for _arg in "$@"; do
    case "$_arg" in
        -y|--yes) ASSUME_YES=true ;;
        --check) CHECK_ONLY=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$_arg" >&2; usage >&2; exit 2 ;;
    esac
done

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Asks on the terminal rather than stdin, so it also works when the script is
# piped in. No terminal and no --yes means no.
confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    if ! ( : </dev/tty ) 2>/dev/null; then
        warn "No terminal to ask on; re-run with --yes to accept."
        return 1
    fi
    printf '%s [y/N] ' "$1" >/dev/tty
    _answer=""
    read -r _answer </dev/tty || _answer=""
    case "$_answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Sets SUDO to what raises this user to root ("" when already root). Fails
# when there is no way to get root.
SUDO=""
find_root() {
    if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then SUDO=""; return 0; fi
    if have sudo; then SUDO="sudo "; return 0; fi
    if have doas; then SUDO="doas "; return 0; fi
    return 1
}

# --- Which OS --------------------------------------------------------------------
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
    Darwin) OS_FAMILY=macos ;;
    Linux) OS_FAMILY=linux ;;
    MINGW*|MSYS*|UCRT*|CLANG*) if have pacman; then OS_FAMILY=msys2; else OS_FAMILY=gitbash; fi ;;
    CYGWIN*) OS_FAMILY=cygwin ;;
    FreeBSD|DragonFly|OpenBSD|NetBSD) OS_FAMILY=bsd ;;
    *) OS_FAMILY=other ;;
esac

os_name() {
    case "$OS_FAMILY" in
        macos) printf 'macOS %s' "$(sw_vers -productVersion 2>/dev/null || uname -r)" ;;
        linux)
            _n=""
            [ -r /etc/os-release ] && _n="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
            printf '%s' "${_n:-Linux $(uname -r)}"
            grep -qi microsoft /proc/version 2>/dev/null && printf ' (WSL)'
            ;;
        msys2) printf 'Windows (MSYS2 %s)' "${MSYSTEM:-MSYS}" ;;
        gitbash) printf 'Windows (Git Bash)' ;;
        cygwin) printf 'Windows (Cygwin)' ;;
        *) printf '%s %s' "$UNAME_S" "$(uname -r 2>/dev/null)" ;;
    esac
}

# --- How to install zsh here -------------------------------------------------------
# plan_install sets INSTALL_DESC and INSTALL_CMD (run with eval), or prints what
# to do by hand and fails.
INSTALL_DESC=""
INSTALL_CMD=""

plan_root_pkg() {   # <description> <command, without sudo>
    if find_root; then
        INSTALL_DESC="$1"
        INSTALL_CMD="${SUDO}$2"
        return 0
    fi
    return 1
}

plan_install() {
    case "$OS_FAMILY" in
        macos)
            if have brew; then INSTALL_DESC="Homebrew's zsh"; INSTALL_CMD="brew install zsh"; return 0; fi
            if have port && plan_root_pkg "MacPorts' zsh" "port install zsh"; then return 0; fi
            err "macOS ships /bin/zsh, and neither Homebrew nor MacPorts is installed to add one."
            err "Install Homebrew (https://brew.sh), then run: brew install zsh"
            return 1
            ;;
        linux)
            _cmd=""
            if have apt-get; then _cmd="apt-get install -y zsh"
            elif have dnf; then _cmd="dnf install -y zsh"
            elif have microdnf; then _cmd="microdnf install -y zsh"
            elif have yum; then _cmd="yum install -y zsh"
            elif have zypper; then _cmd="zypper --non-interactive install zsh"
            elif have pacman; then _cmd="pacman -S --needed --noconfirm zsh"
            elif have apk; then _cmd="apk add zsh"
            elif have xbps-install; then _cmd="xbps-install -y zsh"
            elif have emerge; then _cmd="emerge --ask=n app-shells/zsh"
            fi
            if [ -n "$_cmd" ] && find_root; then
                INSTALL_DESC="the zsh package of $(os_name)"
                INSTALL_CMD="${SUDO}${_cmd}"
                # Fresh machines and containers often have no apt package lists yet.
                case "$_cmd" in apt-get*) INSTALL_CMD="${SUDO}apt-get update && ${INSTALL_CMD}" ;; esac
                return 0
            fi
            if have brew; then INSTALL_DESC="Homebrew's zsh (no root needed)"; INSTALL_CMD="brew install zsh"; return 0; fi
            if [ -n "$_cmd" ]; then
                err "Installing zsh needs root, and there is no sudo or doas. As root, run: ${_cmd}"
            else
                err "No known package manager found. Install zsh from https://www.zsh.org/ or your distribution's packages."
            fi
            return 1
            ;;
        msys2)
            INSTALL_DESC="MSYS2's zsh package"
            INSTALL_CMD="pacman -S --needed --noconfirm zsh"
            return 0
            ;;
        gitbash)
            plan_git_bash
            return $?
            ;;
        cygwin)
            if have apt-cyg; then INSTALL_DESC="Cygwin's zsh package"; INSTALL_CMD="apt-cyg install zsh"; return 0; fi
            err "Run the Cygwin installer you set Cygwin up with and add the zsh package:"
            err "  setup-x86_64.exe --quiet-mode --packages zsh"
            return 1
            ;;
        bsd)
            case "$UNAME_S" in
                OpenBSD) plan_root_pkg "OpenBSD's zsh package" "pkg_add zsh" && return 0 ;;
                NetBSD)
                    if have pkgin; then plan_root_pkg "pkgsrc's zsh" "pkgin -y install zsh" && return 0
                    else plan_root_pkg "pkgsrc's zsh" "pkg_add zsh" && return 0; fi
                    ;;
                *) plan_root_pkg "the zsh package of $(os_name)" "pkg install -y zsh" && return 0 ;;
            esac
            err "Installing zsh needs root, and there is no sudo or doas."
            return 1
            ;;
        *)
            err "Unknown OS '$UNAME_S'. Install zsh from https://www.zsh.org/ or the OS's packages."
            return 1
            ;;
    esac
}

# Git for Windows has no package manager, but it is built on MSYS2, so MSYS2's
# own zsh package runs in it once unpacked into the Git install folder.
MSYS2_REPO="https://repo.msys2.org/msys/x86_64"

plan_git_bash() {
    _git_root="$(cygpath -w / 2>/dev/null || echo /)"
    _missing=""
    for _t in curl tar zstd mktemp; do have "$_t" || _missing="$_missing $_t"; done
    if [ -n "$_missing" ]; then
        err "Git Bash is missing:$_missing. Either:"
        err "  - download the latest zsh-*-x86_64.pkg.tar.zst from $MSYS2_REPO/,"
        err "    unpack it with 7-Zip and copy its usr/ folder into $_git_root, or"
        err "  - use WSL (wsl --install) or MSYS2 (https://www.msys2.org) and run this script there."
        return 1
    fi
    if [ ! -w /usr/bin ]; then
        err "Git for Windows is installed in $_git_root, which only an administrator can write to."
        err "Open Git Bash with 'Run as administrator' and run this script again."
        return 1
    fi
    INSTALL_DESC="MSYS2's zsh package ($MSYS2_REPO), unpacked into Git for Windows at $_git_root"
    INSTALL_CMD="install_zsh_into_git_bash"
    return 0
}

install_zsh_into_git_bash() {
    # The repo listing also has .sig files and older builds: keep the newest package.
    _pkg="$(curl -fsSL "$MSYS2_REPO/" | grep -o 'zsh-[0-9][0-9.]*-[0-9][0-9]*-x86_64\.pkg\.tar\.zst' | sort -u | sort -V | tail -n 1)"
    if [ -z "$_pkg" ]; then
        err "No zsh package found at $MSYS2_REPO/"
        return 1
    fi
    _tmp="$(mktemp -d)" || return 1
    info "Downloading $MSYS2_REPO/$_pkg"
    if ! curl -fSL --retry 3 -o "$_tmp/$_pkg" "$MSYS2_REPO/$_pkg"; then
        rm -rf "$_tmp"; return 1
    fi
    mkdir "$_tmp/root"
    if ! zstd -dc "$_tmp/$_pkg" | tar -xf - -C "$_tmp/root"; then
        rm -rf "$_tmp"; return 1
    fi
    # Only usr/ and etc/: the package's .PKGINFO/.MTREE/.BUILDINFO stay behind.
    cp -R "$_tmp/root/usr/." /usr/ || { rm -rf "$_tmp"; return 1; }
    if [ -d "$_tmp/root/etc" ]; then
        cp -R "$_tmp/root/etc/." /etc/ || { rm -rf "$_tmp"; return 1; }
    fi
    rm -rf "$_tmp"
}

# --- The checks ---------------------------------------------------------------------
zsh_version() { "$1" --version 2>/dev/null | sed -n 's/^zsh \([0-9][0-9.]*\).*/\1/p'; }

info "System: $(os_name) ($(uname -m 2>/dev/null))"

if ! have zsh && [ ! -x /bin/zsh ]; then
    warn "zsh is not installed. The scripts in this repo need it."
    if [ "$CHECK_ONLY" = true ]; then
        plan_install && info "Would install $INSTALL_DESC: $INSTALL_CMD"
        exit 1
    fi
    plan_install || exit 1
    info "Install: $INSTALL_DESC"
    info "Command: $INSTALL_CMD"
    if ! confirm "Install zsh now?"; then
        warn "zsh not installed. Install it yourself with the command above, then run this script again."
        exit 1
    fi
    if ! eval "$INSTALL_CMD"; then
        err "The zsh install failed (see the output above)."
        exit 1
    fi
    hash -r 2>/dev/null || true
    if ! have zsh && [ ! -x /bin/zsh ]; then
        err "The install finished, but zsh is still not on PATH. Open a new terminal and run this script again."
        exit 1
    fi
    info "zsh installed: $(command -v zsh || echo /bin/zsh)"
fi

# The scripts start with #!/bin/zsh, so a zsh only on PATH is not enough.
if [ ! -x /bin/zsh ]; then
    _zsh="$(command -v zsh)"
    warn "zsh is at $_zsh, but the scripts start with #!/bin/zsh and there is no /bin/zsh."
    if [ "$CHECK_ONLY" = true ]; then
        info "Would link /bin/zsh -> $_zsh"
        exit 1
    fi
    if ! find_root; then
        err "Linking /bin/zsh needs root. As root, run: ln -s $_zsh /bin/zsh"
        exit 1
    fi
    if ! confirm "Link /bin/zsh -> $_zsh?"; then
        warn "Without /bin/zsh the scripts cannot start. As root, run: ln -s $_zsh /bin/zsh"
        exit 1
    fi
    ${SUDO}ln -s "$_zsh" /bin/zsh || { err "Could not create /bin/zsh."; exit 1; }
fi

_ver="$(zsh_version /bin/zsh)"
case "$_ver" in
    [0-4].*) warn "zsh $_ver is old; the scripts are written for zsh 5 or newer." ;;
esac
info "zsh is ready: /bin/zsh (zsh ${_ver:-unknown version})"

# helm (Confluent Flink, mirroring, Mission Control) has a cross-platform
# installer in the repo; only report it here, the installer asks before changing anything.
_helm_installer="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/src/utilities/cli_tool_utils/install_helm.sh"
if [ -f "$_helm_installer" ]; then
    /bin/zsh "$_helm_installer" --check 2>&1 | grep -v '^\[TIMER\]' || true
    have helm || info "Install it with: src/utilities/cli_tool_utils/install_helm.sh"
fi
info "Next: the Prerequisites in README.md (oc, cpd-cli, podman, Python + uv)."
exit 0
