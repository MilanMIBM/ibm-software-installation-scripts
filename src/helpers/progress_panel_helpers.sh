#!/bin/zsh
# =============================================================================
# progress_panel_helpers.sh - progress rows pinned at the bottom of the
# terminal, and a parallel job pool that drives them
# -----------------------------------------------------------------------------
# How scripts use it:
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"
#
# Two layers:
#   - panel: N rows redrawn in place at the bottom of the terminal; events
#     (ppanel_event) are printed ABOVE them, so the rows never scroll away.
#       ppanel_open <rows>        ppanel_row <n> <text>       ppanel_draw
#       ppanel_close [keep]       ppanel_event <level> <message...>
#       ppanel_bar <done> <total> [width]   -> REPLY  ([██████░░░░])
#       ppanel_duration <seconds>           -> REPLY  (45s, 14m03s, 1h02m)
#       ppanel_changed <file>     true when the file grew/changed since the
#                                 last call - for probes that parse a log
#   - pool: ppanel_pool_run runs jobs N at a time with retries; one header row
#     plus one row per slot (bar, count, elapsed, detail from a probe).
#
# Event levels: INFO (shown only without a terminal - in a terminal the rows
# already show it), NOTE (always, printed as [INFO]), WARN, ERROR (stderr).
#
# Without a terminal (piped, CI, too few lines, PPANEL_MODE=plain) no rows are
# drawn: every event is printed, and the pool adds a summary line every
# PPANEL_PLAIN_EVERY seconds (default 60).
#
# Settings: PPANEL_MODE=auto|tty|plain (auto: tty when stdout is a terminal and
# TERM is not dumb), PPANEL_PLAIN_EVERY, NO_COLOR.
#
# Notes:
#   - Must be SOURCED (zsh). Guarded via _PPANEL_HELPERS_LOADED.
#   - The functions set their own options (no errexit / nounset / pipefail), so
#     they are safe in `set -euo pipefail` scripts; a pool worker inherits
#     those options.
#   - Rows are cut to the terminal width (a wrapped row would break the
#     in-place redraw); event lines are not.
#   - Nothing else may write to the terminal while a panel is open - pool
#     workers' stdout / stderr go to a file.
# =============================================================================

[[ -n "${_PPANEL_HELPERS_LOADED:-}" ]] && return 0
_PPANEL_HELPERS_LOADED=1

zmodload zsh/datetime
zmodload zsh/zselect 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null

typeset -g _PPANEL_MODE="" _PPANEL_EVENTS_FILE="" _PPANEL_FULL="#" _PPANEL_EMPTY="-" _PPANEL_ELLIPSIS="~"
typeset -gi _PPANEL_ROWS=0 _PPANEL_DRAWN=0 _PPANEL_EVENTS_READ=0 _PPANEL_COLS=80 _PPANEL_LINES=24
typeset -ga _PPANEL_TEXT=() _PPANEL_PENDING=()
typeset -gA _PPANEL_SEEN=()
if [[ "${(L)${LC_ALL:-${LC_CTYPE:-${LANG:-}}}}" == *utf(-|)8* ]]; then
    _PPANEL_FULL="█" _PPANEL_EMPTY="░" _PPANEL_ELLIPSIS="…"
fi

# =============================================================================
# Panel
# =============================================================================

_ppanel_term_size() {
    local -a s
    s=(${=$(stty size </dev/tty 2>/dev/null)})
    _PPANEL_LINES=${s[1]:-24} _PPANEL_COLS=${s[2]:-80}
    (( _PPANEL_COLS > 0 )) || _PPANEL_COLS=80
    (( _PPANEL_LINES > 0 )) || _PPANEL_LINES=24
}

_ppanel_emit() {   # <tty|plain> <level> <message>
    local lvl="$2" on="" off=""
    [[ "$1" == tty && "${lvl}" == INFO ]] && return 0
    if [[ "$1" == tty && -z "${NO_COLOR:-}" ]]; then
        case "${lvl}" in
            WARN)  on=$'\e[33m' off=$'\e[0m' ;;
            ERROR) on=$'\e[31m' off=$'\e[0m' ;;
        esac
    fi
    if [[ "${lvl}" == (WARN|ERROR) ]]; then
        print -r -- "${on}[${lvl}]${off} $3" >&2
    else
        print -r -- "[INFO] $3"
    fi
}

# Events appended by pool workers (complete lines only: a line still being
# written is picked up on the next draw).
_ppanel_drain_events() {
    [[ -n "${_PPANEL_EVENTS_FILE}" && -s "${_PPANEL_EVENTS_FILE}" ]] || return 0
    local raw i
    local -a lines
    raw="$(cat -- "${_PPANEL_EVENTS_FILE}"; print -rn x)"
    lines=("${(@f)${raw%x}}")
    lines[-1]=()
    for (( i = _PPANEL_EVENTS_READ + 1; i <= ${#lines}; i++ )); do
        _PPANEL_PENDING+=("${lines[i]}")
    done
    _PPANEL_EVENTS_READ=${#lines}
}

ppanel_open() {   # <rows>
    setopt localoptions unset noerrexit nopipefail
    local mode="${PPANEL_MODE:-auto}"
    if [[ "${mode}" != (tty|plain) ]]; then
        [[ -t 1 && "${TERM:-dumb}" != dumb ]] && mode=tty || mode=plain
    fi
    _PPANEL_ROWS=${1:-1} _PPANEL_DRAWN=0 _PPANEL_TEXT=() _PPANEL_PENDING=()
    if [[ "${mode}" == tty ]]; then
        _ppanel_term_size
        (( _PPANEL_ROWS < _PPANEL_LINES - 1 )) || mode=plain   # no room to pin them
    fi
    _PPANEL_MODE="${mode}"
    [[ "${mode}" == tty ]] && print -rn -- $'\e[?25l'
    return 0
}

ppanel_row() {   # <n> <text> - shown on the next draw
    _PPANEL_TEXT[$1]="${2//$'\t'/ }"
}

ppanel_draw() {
    setopt localoptions unset noerrexit nopipefail
    [[ -n "${_PPANEL_MODE}" ]] || return 0
    _ppanel_drain_events
    local e line out="" i
    local -a shown=()
    if [[ "${_PPANEL_MODE}" == plain ]]; then
        for e in "${_PPANEL_PENDING[@]}"; do _ppanel_emit plain "${e%%$'\t'*}" "${e#*$'\t'}"; done
        _PPANEL_PENDING=()
        return 0
    fi
    for e in "${_PPANEL_PENDING[@]}"; do [[ "${e%%$'\t'*}" == INFO ]] || shown+=("${e}"); done
    _PPANEL_PENDING=()
    _ppanel_term_size
    (( _PPANEL_DRAWN )) && out=$'\e['"${_PPANEL_DRAWN}"$'A\r'
    if (( ${#shown} )); then
        # clear the rows, print the events where they were, rows go below them
        print -rn -- "${out}"$'\e[J'
        out=""
        for e in "${shown[@]}"; do _ppanel_emit tty "${e%%$'\t'*}" "${e#*$'\t'}"; done
    fi
    for (( i = 1; i <= _PPANEL_ROWS; i++ )); do
        line="${_PPANEL_TEXT[i]:-}"
        (( ${#line} < _PPANEL_COLS )) || line="${line[1,_PPANEL_COLS-2]}${_PPANEL_ELLIPSIS}"
        out+="${line}"$'\e[K\n'
    done
    print -rn -- "${out}"
    _PPANEL_DRAWN=${_PPANEL_ROWS}
}

ppanel_close() {   # [keep] - keep: leave the last rows on screen
    setopt localoptions unset noerrexit nopipefail
    [[ -n "${_PPANEL_MODE}" ]] || return 0
    ppanel_draw
    if [[ "${_PPANEL_MODE}" == tty ]]; then
        if [[ "${1:-}" != keep ]] && (( _PPANEL_DRAWN )); then
            print -rn -- $'\e['"${_PPANEL_DRAWN}"$'A\r\e[J'
        fi
        print -rn -- $'\e[?25h'
    fi
    _PPANEL_MODE="" _PPANEL_DRAWN=0 _PPANEL_ROWS=0 _PPANEL_TEXT=()
    return 0
}

# ppanel_event <INFO|NOTE|WARN|ERROR> <message...>
#   With a panel open the line goes above the rows; from a pool worker it is
#   handed to the pool's panel; otherwise it is printed as is.
ppanel_event() {
    setopt localoptions unset noerrexit nopipefail
    local lvl="$1"; shift
    local msg="${${*}//$'\n'/ }"
    if [[ -n "${_PPANEL_IN_WORKER:-}" ]]; then
        print -r -- "${lvl}"$'\t'"${msg}" >> "${_PPANEL_EVENTS_FILE}"
    elif [[ -n "${_PPANEL_MODE}" ]]; then
        _PPANEL_PENDING+=("${lvl}"$'\t'"${msg}")
        [[ "${_PPANEL_MODE}" == plain || "${lvl}" != INFO ]] && ppanel_draw
    else
        _ppanel_emit plain "${lvl}" "${msg}"
    fi
    return 0
}

ppanel_bar() {   # <done> <total> [width] -> REPLY; an unknown total (empty / 0) gives an empty bar
    setopt localoptions unset noerrexit nopipefail
    local -i d=${1:-0} t=${2:-0} w=${3:-20} f=0
    if (( t > 0 )); then
        (( d > t )) && d=t
        (( d < 0 )) && d=0
        f=$(( d * w / t ))
    fi
    REPLY="[${(pl:f::$_PPANEL_FULL:)${:-}}${(pl:w-f::$_PPANEL_EMPTY:)${:-}}]"
}

ppanel_duration() {   # <seconds> -> REPLY
    local -i s=${1:-0}
    if (( s < 60 )); then
        REPLY="${s}s"
    elif (( s < 3600 )); then
        printf -v REPLY '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf -v REPLY '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    fi
}

ppanel_changed() {   # <file>: true when its size / mtime differ from the last call (or it is missing)
    local -A st
    zstat -H st -- "$1" 2>/dev/null || { _PPANEL_SEEN[$1]=""; return 0; }
    [[ "${_PPANEL_SEEN[$1]:-}" == "${st[size]}:${st[mtime]}" ]] && return 1
    _PPANEL_SEEN[$1]="${st[size]}:${st[mtime]}"
    return 0
}

# =============================================================================
# Pool
# =============================================================================
# ppanel_pool_run [options] [--] <job>...
#   -w FN     worker (required): `FN <job>` runs in a background subshell with
#             stdout / stderr captured; exit 0 = done. It sees PPANEL_SLOT,
#             PPANEL_ATTEMPT and PPANEL_ATTEMPTS, and may call ppanel_event and
#             ppanel_job_reason <text> (shown in the retry / failure message).
#   -p FN     probe: `FN <job> <attempt>` runs in THIS shell for each running
#             job on every refresh. It sets PPANEL_DONE, PPANEL_TOTAL (whole
#             numbers, may stay empty) and PPANEL_DETAIL, and may call
#             ppanel_event (e.g. the first error it sees in a log).
#   -l FN     label: `FN <job>` sets REPLY (default: the job itself)
#   -c FN     cleanup on INT / TERM, after the workers are killed (e.g. stop
#             what they started elsewhere, such as inside a container)
#   -j N      slots (default 4)            -a N  attempts per job (default 1)
#   -d S      seconds between attempts (60) -i S  refresh seconds (1)
#   -t TEXT   title, also the event prefix -k WORD  what a job is called (jobs)
#   -u WORD   what the units are (items)
#   -W NAME   associative array job -> expected units: the header then shows
#             units across all jobs, and it is a job's total when the probe
#             gives none
# Jobs are started in the order given. Returns 0 when every job succeeded,
# else 1; PPANEL_FAILED holds the failed jobs, PPANEL_ELAPSED the seconds.
# INT / TERM: workers killed, cleanup run, exit 130 / 143.
# =============================================================================

ppanel_job_reason() {   # <text> - from a pool worker, before it fails
    print -r -- "${${*}//$'\n'/ }" > "${PPANEL_STATE_DIR}/slot.${PPANEL_SLOT}.reason"
}

_ppanel_state() {   # <file> <words...> - replaced whole, never read half-written
    print -r -- "${@:2}" > "$1.tmp" && mv -f -- "$1.tmp" "$1"
}

_ppanel_read_state() {   # <file> -> reply (kind attempt [epoch])
    reply=()
    [[ -s "$1" ]] && reply=(${=$(<"$1")})
    return 0
}

_ppanel_pool_reason() {   # <slot file> <exit code> -> REPLY
    local r=""
    [[ -s "$1.reason" ]] && r="$(<"$1.reason")"
    [[ -z "${r}" && -s "$1.out" ]] && r="$(tail -n 1 -- "$1.out")"
    REPLY="exit $2${r:+: ${r}}"
}

_ppanel_kill_tree() {   # <pid> - children first
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do _ppanel_kill_tree "${c}"; done
    kill -TERM "$1" 2>/dev/null
    return 0
}

_ppanel_sleep() {   # <seconds>
    if (( ${+builtins[zselect]} )); then
        zselect -t $(( ${1:-1} * 100 ))
    else
        sleep "${1:-1}"
    fi
    return 0
}

# Background: one job in one slot, with its attempts.
_ppanel_pool_slot() {   # <state dir> <slot> <worker> <attempts> <delay> <title> <label> <job>
    local st="$1/slot.$2" rc=0
    local _PPANEL_IN_WORKER=1 PPANEL_STATE_DIR="$1" PPANEL_SLOT="$2" PPANEL_ATTEMPTS="$4" PPANEL_ATTEMPT
    for (( PPANEL_ATTEMPT = 1; PPANEL_ATTEMPT <= $4; PPANEL_ATTEMPT++ )); do
        rm -f -- "${st}.reason"
        _ppanel_state "${st}" run "${PPANEL_ATTEMPT}"
        "$3" "$8" > "${st}.out" 2>&1
        rc=$?
        if (( rc == 0 )); then
            _ppanel_state "${st}" ok "${PPANEL_ATTEMPT}"
            return 0
        fi
        (( PPANEL_ATTEMPT < $4 )) || break
        _ppanel_pool_reason "${st}" "${rc}"
        ppanel_event WARN "$6: $7 attempt ${PPANEL_ATTEMPT}/$4 failed (${REPLY}), retrying in $5 s"
        _ppanel_state "${st}" wait "${PPANEL_ATTEMPT}" $(( EPOCHSECONDS + $5 ))
        sleep "$5"
    done
    _ppanel_state "${st}" fail "${PPANEL_ATTEMPT}" "${rc}"
    return 1
}

# INT / TERM trap of ppanel_pool_run (runs in its scope: slot_pid, dir, ...)
_ppanel_pool_abort() {   # <exit code>
    local p
    ppanel_close
    _PPANEL_EVENTS_FILE=""
    _ppanel_emit plain WARN "${title}: interrupted - stopping the running ${noun}"
    for p in "${slot_pid[@]}"; do [[ -n "${p}" ]] && _ppanel_kill_tree "${p}"; done
    wait 2>/dev/null
    [[ -n "${cleanup}" ]] && "${cleanup}" >/dev/null 2>&1
    rm -rf -- "${dir}"
    exit "$1"
}

ppanel_pool_run() {
    setopt localoptions localtraps unset noerrexit nopipefail
    local -A o
    zparseopts -D -F -A o w: p: l: c: j: a: d: i: t: k: u: W: \
        || { print -u2 -r -- "ppanel_pool_run: unknown option"; return 2; }
    local worker="${o[-w]:-}" probe="${o[-p]:-}" labeler="${o[-l]:-}" cleanup="${o[-c]:-}"
    local title="${o[-t]:-progress}" noun="${o[-k]:-jobs}" unit="${o[-u]:-items}" wname="${o[-W]:-}"
    local -i slots=${o[-j]:-4} attempts=${o[-a]:-1} delay=${o[-d]:-60} every=${o[-i]:-1}
    [[ -n "${worker}" ]] || { print -u2 -r -- "ppanel_pool_run: -w <worker> is required"; return 2; }
    (( slots >= 1 && attempts >= 1 && every >= 1 )) || { print -u2 -r -- "ppanel_pool_run: -j, -a, -i must be >= 1"; return 2; }

    local -a queue=("$@")
    local -i njobs=${#queue}
    typeset -ga PPANEL_FAILED=()
    typeset -gi PPANEL_ELAPSED=0
    (( njobs )) || return 0
    (( slots > njobs )) && slots=njobs

    # labels, widths and the expected units, once
    local -A weight label units total
    [[ -n "${wname}" ]] && weight=("${(@Pkv)wname}")
    local job REPLY
    local -i lw=4 cw=1 utotal=0 sw=${#slots}
    for job in "${queue[@]}"; do
        REPLY="${job}"
        [[ -n "${labeler}" ]] && "${labeler}" "${job}"
        label[$job]="${REPLY}"
        (( ${#REPLY} > lw )) && lw=${#REPLY}
        (( utotal += ${weight[$job]:-0} ))
        (( ${#${weight[$job]:-}} > cw )) && cw=${#${weight[$job]:-}}
    done
    (( lw > 32 )) && lw=32
    cw=$(( cw * 2 + 1 ))

    local dir
    dir="$(mktemp -d "${${TMPDIR:-/tmp}%/}/ppanel.XXXXXX")" || return 2
    _PPANEL_EVENTS_FILE="${dir}/events" _PPANEL_EVENTS_READ=0
    : > "${_PPANEL_EVENTS_FILE}"

    local -a slot_job slot_pid slot_t0 reply
    trap '_ppanel_pool_abort 130' INT
    trap '_ppanel_pool_abort 143' TERM

    ppanel_open $(( slots + 1 ))
    local -i t0=${EPOCHSECONDS} ok=0 bad=0 s running udone bw jdone jtot
    local -i plain_every=${PPANEL_PLAIN_EVERY:-60} next_plain
    next_plain=$(( EPOCHSECONDS + plain_every ))
    local st kind try lab cnt pct row head runlist pid
    while :; do
        # reap finished slots, start queued jobs
        for (( s = 1; s <= slots; s++ )); do
            st="${dir}/slot.${s}"
            if [[ -n "${slot_job[s]:-}" ]]; then
                _ppanel_read_state "${st}"
                if [[ "${reply[1]:-}" == (ok|fail) ]] || ! kill -0 "${slot_pid[s]}" 2>/dev/null; then
                    wait "${slot_pid[s]}" 2>/dev/null
                    _ppanel_read_state "${st}"
                    job="${slot_job[s]}"
                    ppanel_duration $(( EPOCHSECONDS - slot_t0[s] ))
                    if [[ "${reply[1]:-}" == ok ]]; then
                        (( ok += 1 ))
                        units[$job]=${total[$job]:-${weight[$job]:-0}}
                        ppanel_event INFO "${title}: ${label[$job]} done in ${REPLY}"
                    else
                        (( bad += 1 ))
                        PPANEL_FAILED+=("${job}")
                        lab="${REPLY}"
                        _ppanel_pool_reason "${st}" "${reply[3]:-?}"
                        ppanel_event ERROR "${title}: ${label[$job]} failed after ${reply[2]:-?} attempt(s) in ${lab} (${REPLY})"
                    fi
                    slot_job[s]="" slot_pid[s]=""
                fi
            fi
            if [[ -z "${slot_job[s]:-}" ]] && (( ${#queue} )); then
                job="${queue[1]}"
                shift queue
                rm -f -- "${st}" "${st}.reason" "${st}.out"
                _ppanel_pool_slot "${dir}" "${s}" "${worker}" "${attempts}" "${delay}" "${title}" "${label[$job]}" "${job}" </dev/null &
                pid=$!   # not slot_pid[s]=$! - zsh leaves $! unexpanded there
                slot_pid[s]=${pid} slot_job[s]="${job}" slot_t0[s]=${EPOCHSECONDS}
                ppanel_event INFO "${title}: ${label[$job]} started"
            fi
        done

        # one row per slot
        [[ "${_PPANEL_MODE}" == tty ]] && _ppanel_term_size
        bw=$(( _PPANEL_COLS - sw - lw - cw - 52 ))
        (( bw > 30 )) && bw=30
        (( bw < 8 )) && bw=8
        running=0 runlist=""
        for (( s = 1; s <= slots; s++ )); do
            job="${slot_job[s]:-}"
            if [[ -z "${job}" ]]; then
                ppanel_row $(( s + 1 )) "${(l:sw:)s} ${(r:lw:):-idle}"
                continue
            fi
            (( running += 1 ))
            _ppanel_read_state "${dir}/slot.${s}"
            kind="${reply[1]:-run}" try="${reply[2]:-1}"
            PPANEL_DONE="" PPANEL_TOTAL="" PPANEL_DETAIL=""
            [[ -n "${probe}" ]] && "${probe}" "${job}" "${try}"
            jtot=${PPANEL_TOTAL:-${weight[$job]:-0}}
            jdone=${PPANEL_DONE:-0}
            (( jtot > 0 && jdone > jtot )) && jdone=jtot
            units[$job]=${jdone} total[$job]=${jtot}
            if [[ "${kind}" == wait ]]; then
                PPANEL_DETAIL="retry $(( try + 1 ))/${attempts} in $(( ${reply[3]:-0} - EPOCHSECONDS ))s"
            elif (( try > 1 )); then
                PPANEL_DETAIL="try ${try}/${attempts}${PPANEL_DETAIL:+ · ${PPANEL_DETAIL}}"
            fi
            lab="${label[$job]}"
            (( ${#lab} > lw )) && lab="${lab[1,lw-1]}${_PPANEL_ELLIPSIS}"
            cnt="${jdone}" pct=""
            (( jtot > 0 )) && cnt="${jdone}/${jtot}" pct="$(( jdone * 100 / jtot ))%"
            ppanel_bar "${jdone}" "${jtot}" "${bw}"
            row="${(l:sw:)s} ${(r:lw:)lab} ${REPLY} ${(l:cw:)cnt} ${(l:4:)pct}"
            ppanel_duration $(( EPOCHSECONDS - slot_t0[s] ))
            ppanel_row $(( s + 1 )) "${row}  ${(l:6:)REPLY}  ${PPANEL_DETAIL}"
            runlist+="${runlist:+, }${label[$job]} ${cnt}"
        done

        # header: units (or jobs) across the whole run
        udone=0
        for job in "${(@k)units}"; do (( udone += units[$job] )); done
        if (( utotal > 0 )); then
            ppanel_bar "${udone}" "${utotal}" "${bw}"
            head="${title}  ${REPLY} ${udone}/${utotal} ${unit} ($(( udone * 100 / utotal ))%)"
        else
            ppanel_bar $(( ok + bad )) "${njobs}" "${bw}"
            head="${title}  ${REPLY}"
        fi
        head+=" · ${noun} ${ok}/${njobs} done"
        (( bad )) && head+=", ${bad} failed"
        ppanel_duration $(( EPOCHSECONDS - t0 ))
        head+=" · ${running} running, ${#queue} queued · ${REPLY}"
        ppanel_row 1 "${head}"
        if [[ "${_PPANEL_MODE}" == plain ]] && (( EPOCHSECONDS >= next_plain )); then
            ppanel_event INFO "${head}${runlist:+ - ${runlist}}"
            next_plain=$(( EPOCHSECONDS + plain_every ))
        fi
        ppanel_draw

        (( running == 0 && ${#queue} == 0 )) && break
        _ppanel_sleep "${every}"
    done

    PPANEL_ELAPSED=$(( EPOCHSECONDS - t0 ))
    ppanel_close
    _PPANEL_EVENTS_FILE=""
    rm -rf -- "${dir}"
    ppanel_duration "${PPANEL_ELAPSED}"
    if (( bad )); then
        _ppanel_emit plain WARN "${title}: ${ok}/${njobs} ${noun} done, ${bad} failed, in ${REPLY}"
        return 1
    fi
    _ppanel_emit plain NOTE "${title}: ${ok}/${njobs} ${noun} done in ${REPLY}"
    return 0
}
