#!/usr/bin/env bash
#
#  Benchy Ult  --  minibench v2
#  A portable CPU + memory benchmark for any machine with bash.
#
#  Targets: Linux, WSL, macOS (bash 3.2 + BSD tools), Windows Git Bash /
#  MSYS2 / Cygwin, BSDs, BusyBox userlands. No GNU-only flags are required;
#  where a GNU extension helps, it is detected first and has a fallback.
#
#  Usage:  bash benchy-ult.sh [options]        (run with -h for the list)
#
#  How it stays consistent from run to run and machine to machine:
#    * Fixed work, timed once: the clock is read only at the start and end of
#      each trial, never inside the measured loop.
#    * Self-calibrating: each test sizes its work to ~TRIAL_SECS per trial, so
#      a Raspberry Pi and a 64-core server both get statistically useful runs.
#    * The calibration pass doubles as a warmup and is thrown away.
#    * Several trials per test; the median is reported along with the spread,
#      and a noisy run is flagged instead of silently trusted.
#    * LC_ALL=C everywhere, so decimals never turn into commas.
#    * Memory tests use small, fixed buffers (no "allocate 45% of RAM"), and
#      every method's result is sanity-checked before the cascade accepts it.
#

# ---- re-exec under bash if started by sh/dash/ash ---------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1 && [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "Benchy Ult needs bash. Run it as: bash benchy-ult.sh" >&2
    exit 1
fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
    echo "Benchy Ult needs bash 3.2 or newer (found $BASH_VERSION)." >&2
    exit 1
fi

set -u
export LC_ALL=C
export LANG=C

BENCHY_VERSION="2.0.0"

# ---- defaults (each can also be set by environment variable) ---------------
TRIALS="${BENCHY_TRIALS:-5}"              # timed trials per test
TRIAL_SECS="${BENCHY_TRIAL_SECS:-2}"      # target length of one trial
MEM_METHOD="${BENCHY_MEM_METHOD:-auto}"   # auto|dd|tmpfs|awk|powershell
FORCE_FAIL="${BENCHY_FORCE_FAIL:-}"       # e.g. "dd tmpfs awk" to test the cascade
LEGACY="${BENCHY_LEGACY:-1}"              # 1 = also print v1-scale scores
LEGACY_SECS=5
COLOR_MODE="${BENCHY_COLOR:-auto}"        # auto|always|never
RESULT_FILE="${BENCHY_RESULT_FILE:-benchy_ult_results.txt}"
HISTORY_FILE="${BENCHY_HISTORY_FILE:-benchy_ult_history.csv}"
WRITE_HISTORY=1
CORES_OVERRIDE="${BENCHY_CORES:-}"

# ---- reference machine: every score is 1000 on this box ---------------------
# 4 vCPU Intel Xeon @ 2.30GHz cloud VM (KVM), 16 GB, Ubuntu 24.04, bash 5.2.21,
# GNU Awk 5.2.1, GNU coreutils 9.4. Medians of --thorough runs, Nov 2026.
REF_SINGLE=537000       # ops/s, one core
REF_MULTI=2210000       # ops/s, all cores
# Memory references, in MiB/s, one per method (read by name in calc_scores).
# PowerShell has none yet: it needs a Windows box to measure.
# shellcheck disable=SC2034
REF_MEM_dd=7100 REF_MEM_tmpfs=2750 REF_MEM_awk=1750 REF_MEM_powershell=""

# =============================================================================
#  Output helpers and colour
# =============================================================================
USE_COLOR=0
COLORS=8
C_RST="" C_B="" C_DIM="" C_RED="" C_GRN="" C_YEL="" C_MAG="" C_CYN="" C_GRY=""

setup_color() {
    case "$COLOR_MODE" in
        always) USE_COLOR=1 ;;
        never)  USE_COLOR=0 ;;
        *)
            if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
                USE_COLOR=1
            fi
            ;;
    esac
    [ "$USE_COLOR" -eq 1 ] || return 0

    local n
    n=$(tput colors 2>/dev/null) || n=""
    case "$n" in ''|*[!0-9]*) n=8 ;; esac
    COLORS=$n
    # Terminals that do 256 colours but don't advertise it in TERM.
    case "${COLORTERM:-}" in truecolor|24bit) COLORS=256 ;; esac
    case "${TERM:-}" in *256color*|xterm-kitty|alacritty|wezterm) COLORS=256 ;; esac
    [ -n "${WT_SESSION:-}" ] && COLORS=256          # Windows Terminal
    [ "${TERM_PROGRAM:-}" = "mintty" ] && COLORS=256 # Git Bash default
    [ -n "${MSYSTEM:-}" ] && [ "${TERM:-}" = "xterm" ] && COLORS=256

    local e=$'\033'
    C_RST="${e}[0m" C_B="${e}[1m" C_DIM="${e}[2m"
    C_RED="${e}[31m" C_GRN="${e}[32m" C_YEL="${e}[33m"
    C_MAG="${e}[35m" C_CYN="${e}[36m" C_GRY="${e}[90m"
}

say()     { printf '%s\n' "$*"; }
info()    { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()      { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()     { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
section() {
    printf '\n%s%s== %s %s%s\n' "$C_B" "$C_MAG" "$1" \
        "$(printf '%*s' $((60 - ${#1})) '' | tr ' ' '=')" "$C_RST"
}

# Paint one line with a diagonal colour gradient (row shifts the phase).
paint_line() {
    local line=$1 row=$2 i chunk idx code out=""
    if [ "$USE_COLOR" -ne 1 ]; then
        printf '%s\n' "$line"
        return
    fi
    local pal256="201 200 165 129 93 57 63 69 75 81 87 51 50 49"
    local pal8="35 35 34 34 36 36"
    local pal
    # shellcheck disable=SC2206
    if [ "$COLORS" -ge 256 ]; then pal=($pal256); else pal=($pal8); fi
    local np=${#pal[@]} last=-1
    i=0
    while [ "$i" -lt "${#line}" ]; do
        chunk=${line:i:3}
        idx=$(( (i / 6 + row) % np ))
        if [ "$idx" -ne "$last" ]; then
            if [ "$COLORS" -ge 256 ]; then
                code=$'\033[1;38;5;'"${pal[$idx]}m"
            else
                code=$'\033[1;'"${pal[$idx]}m"
            fi
            out="$out$code"
            last=$idx
        fi
        out="$out$chunk"
        i=$((i + 3))
    done
    printf '%s%s\n' "$out" "$C_RST"
}

print_banner() {
    local row=0 line
    printf '\n'
    while IFS= read -r line; do
        paint_line "$line" "$row"
        row=$((row + 1))
    done <<'EOF'
   .        *            .         +          .          *     .
         ____  _______   __________  ____  __   __  ____  ______
   *    / __ )/ ____/ | / / ____/ / / /\ \/ /  / / / / / /_  __/
       / __  / __/ /  |/ / /   / /_/ /  \  /  / / / / /   / /    .
  .   / /_/ / /___/ /|  / /___/ __  /   / /  / /_/ / /___/ /
     /_____/_____/_/ |_/\____/_/ /_/   /_/   \____/_____/_/     *
   +        .          *            .            +          .
EOF
    printf '   %s%s>>>  U L T I M A T E   E D I T I O N  <<<%s   %sminibench v%s%s\n' \
        "$C_B" "$C_YEL" "$C_RST" "$C_GRY" "$BENCHY_VERSION" "$C_RST"
    printf '   %sone script . any bash . same numbers%s\n' "$C_DIM" "$C_RST"
}

usage() {
    cat <<EOF
Benchy Ult $BENCHY_VERSION -- portable CPU + memory benchmark (minibench v2)

Usage: bash benchy-ult.sh [options]

  -q, --quick            3 trials of 0.5 s, no legacy scores (~15 s total)
      --thorough         9 trials of 3 s (~2-3 min, steadiest numbers)
  -t, --trials N         timed trials per test (default $TRIALS)
  -s, --seconds S        target seconds per trial (default $TRIAL_SECS)
  -m, --mem-method M     auto|dd|tmpfs|awk|powershell (default $MEM_METHOD)
      --no-legacy        skip the v1-scale scores
  -o, --output FILE      results file (default $RESULT_FILE)
      --no-history       don't append to $HISTORY_FILE
      --color / --no-color
  -h, --help             this help
  -V, --version          print version

Environment: BENCHY_TRIALS, BENCHY_TRIAL_SECS, BENCHY_MEM_METHOD, BENCHY_LEGACY,
BENCHY_CORES, BENCHY_COLOR, NO_COLOR, BENCHY_CLOCK, BENCHY_RESULT_FILE, BENCHY_HISTORY_FILE,
BENCHY_FORCE_FAIL (space-separated memory methods to treat as failed, for
testing the fallback cascade, e.g. BENCHY_FORCE_FAIL="dd tmpfs awk").
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -q|--quick)      TRIALS=3; TRIAL_SECS=0.5; LEGACY=0 ;;
            --thorough)      TRIALS=9; TRIAL_SECS=3 ;;
            -t|--trials)     [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }; TRIALS=$2; shift ;;
            -s|--seconds)    [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }; TRIAL_SECS=$2; shift ;;
            -m|--mem-method) [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }; MEM_METHOD=$2; shift ;;
            --no-legacy)     LEGACY=0 ;;
            -o|--output)     [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }; RESULT_FILE=$2; shift ;;
            --no-history)    WRITE_HISTORY=0 ;;
            --color)         COLOR_MODE=always ;;
            --no-color)      COLOR_MODE=never ;;
            -h|--help)       usage; exit 0 ;;
            -V|--version)    echo "$BENCHY_VERSION"; exit 0 ;;
            *) err "Unknown option: $1 (try -h)"; exit 2 ;;
        esac
        shift
    done
    case "$TRIALS" in ''|*[!0-9]*) err "--trials must be a whole number"; exit 2 ;; esac
    if [ "$TRIALS" -lt 1 ] || [ "$TRIALS" -gt 99 ]; then err "--trials must be 1-99"; exit 2; fi
    if ! awk -v s="$TRIAL_SECS" 'BEGIN{exit !(s ~ /^[0-9]*\.?[0-9]+$/ && s+0 >= 0.1 && s+0 <= 60)}'; then
        err "--seconds must be a number from 0.1 to 60"; exit 2
    fi
    case "$MEM_METHOD" in auto|dd|tmpfs|awk|powershell) ;; *)
        err "--mem-method must be auto, dd, tmpfs, awk or powershell"; exit 2 ;;
    esac
}

# =============================================================================
#  Clock: microseconds since the epoch, without forking when possible
# =============================================================================
CLOCK="" _NOW=0 _T0=0 _ELAPSED_US=0 DATE_NS_OK=0

is_digits() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

clock_init() {
    local d
    d=$(date +%s%N 2>/dev/null) || d=""
    is_digits "$d" && [ "${#d}" -ge 18 ] && DATE_NS_OK=1

    # BENCHY_CLOCK forces a clock source (for testing the fallbacks).
    case "${BENCHY_CLOCK:-auto}" in
        epochrealtime|date-ns|perl|python|date-s) CLOCK=$BENCHY_CLOCK; return ;;
    esac

    # bash 5+: $EPOCHREALTIME, no fork at all.
    d="${EPOCHREALTIME:-}"
    d="${d//[!0-9]/}"
    if is_digits "$d" && [ "${#d}" -ge 16 ]; then CLOCK=epochrealtime; return; fi
    # GNU date (Linux, Git Bash, MSYS2, Cygwin, WSL).
    if [ "$DATE_NS_OK" -eq 1 ]; then CLOCK=date-ns; return; fi
    # perl ships with macOS and Git for Windows.
    d=$(perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000000)' 2>/dev/null) || d=""
    if is_digits "$d"; then CLOCK=perl; return; fi
    # python3, but not the macOS/Windows "install me" stubs.
    d=$(python3 -c 'import time; print(int(time.time()*1000000))' 2>/dev/null) || d=""
    if is_digits "$d"; then CLOCK=python; return; fi
    CLOCK=date-s
}

clock_now() {
    case "$CLOCK" in
        epochrealtime) _NOW="${EPOCHREALTIME//[!0-9]/}" ;;
        date-ns) _NOW=$(date +%s%N); _NOW=$((_NOW / 1000)) ;;
        perl)    _NOW=$(perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000000)') ;;
        python)  _NOW=$(python3 -c 'import time; print(int(time.time()*1000000))') ;;
        *)       _NOW=$(( $(date +%s) * 1000000 )) ;;
    esac
}
t_start() {
    clock_now
    if [ "$CLOCK" = "date-s" ]; then   # line up with the next tick of a 1 s clock
        local t=$_NOW
        while [ "$_NOW" -eq "$t" ]; do clock_now; done
    fi
    _T0=$_NOW
}
t_stop()  { clock_now; _ELAPSED_US=$((_NOW - _T0)); }

# =============================================================================
#  System detection
# =============================================================================
OS_KIND="" OS_PRETTY="" ARCH="" HOST="" CPU_MODEL="" CORES=1 MEM_TOTAL_MB=0
AWK_FLAVOR="" DD_FLAVOR="" LOAD1="" TMPD="" POLL=1 SHM_FILE=""

detect_system() {
    local s r
    s=$(uname -s 2>/dev/null) || s=unknown
    r=$(uname -r 2>/dev/null) || r=""
    ARCH=$(uname -m 2>/dev/null) || ARCH=unknown
    HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null) || HOST=unknown

    case "$s" in
        Linux)
            OS_KIND=linux
            if grep -qi microsoft /proc/version 2>/dev/null; then OS_KIND=wsl; fi
            OS_PRETTY=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
            [ -n "$OS_PRETTY" ] || OS_PRETTY="Linux"
            OS_PRETTY="$OS_PRETTY, kernel $r"
            [ "$OS_KIND" = wsl ] && OS_PRETTY="$OS_PRETTY (WSL)"
            ;;
        Darwin)
            OS_KIND=macos
            OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null), Darwin $r"
            ;;
        MINGW*|MSYS*)
            OS_KIND=windows
            OS_PRETTY="Windows via ${MSYSTEM:+$MSYSTEM }MSYS2/Git Bash ($s)"
            ;;
        CYGWIN*)
            OS_KIND=windows
            OS_PRETTY="Windows via Cygwin ($s)"
            ;;
        *BSD|DragonFly)
            OS_KIND=bsd; OS_PRETTY="$s $r" ;;
        *)
            OS_KIND=other; OS_PRETTY="$s $r" ;;
    esac

    # Logical cores.
    local n=""
    if [ -n "$CORES_OVERRIDE" ]; then n=$CORES_OVERRIDE; fi
    is_digits "$n" || n=$(nproc 2>/dev/null) || n=""
    is_digits "$n" || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
    is_digits "$n" || n=$(sysctl -n hw.logicalcpu 2>/dev/null) || n=""
    is_digits "$n" || n=$(sysctl -n hw.ncpu 2>/dev/null) || n=""
    is_digits "$n" || n="${NUMBER_OF_PROCESSORS:-}"
    is_digits "$n" || n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || n=""
    is_digits "$n" && [ "$n" -ge 1 ] || n=1
    CORES=$n

    # CPU model.
    CPU_MODEL=$(awk -F: '/^model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    [ -n "$CPU_MODEL" ] || CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/^Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
    [ -n "$CPU_MODEL" ] || CPU_MODEL=$(awk -F: '/^Model/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    [ -n "$CPU_MODEL" ] || CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    [ -n "$CPU_MODEL" ] || CPU_MODEL=$(sysctl -n hw.model 2>/dev/null)
    [ -n "$CPU_MODEL" ] || CPU_MODEL="${PROCESSOR_IDENTIFIER:-unknown ($ARCH)}"

    # Total RAM.
    n=$(awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null) || n=""
    if ! is_digits "$n" || [ "$n" -eq 0 ]; then
        n=$(sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.physmem 2>/dev/null) || n=""
        if is_digits "$n"; then n=$((n / 1048576)); else n=0; fi
    fi
    MEM_TOTAL_MB=$n

    # Load average (Linux, WSL, macOS, BSD).
    LOAD1=$(awk '{print $1; exit}' /proc/loadavg 2>/dev/null) || LOAD1=""
    [ -n "$LOAD1" ] || LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1}') || LOAD1=""

    # Tool flavours, for the record (different awk/dd builds differ in speed).
    AWK_FLAVOR=$(awk --version 2>&1 | head -n 1)
    case "$AWK_FLAVOR" in
        *"GNU Awk"*|mawk*|*"awk version"*) ;;
        *BusyBox*|*usage*|*Usage*|*unrecognized*|*illegal*|*unknown*) AWK_FLAVOR=$(awk -W version 2>&1 | head -n 1)
            case "$AWK_FLAVOR" in mawk*) ;; *) AWK_FLAVOR="awk (busybox/bsd)";; esac ;;
    esac
    AWK_FLAVOR=$(printf '%s' "$AWK_FLAVOR" | cut -d, -f1 | cut -c1-40)
    DD_FLAVOR=$(dd --version 2>&1 | head -n 1)
    case "$DD_FLAVOR" in
        *coreutils*) ;;
        *BusyBox*) DD_FLAVOR="busybox dd" ;;
        *) DD_FLAVOR="bsd/other dd" ;;
    esac
}

make_tmpdir() {
    TMPD=$(mktemp -d 2>/dev/null) || TMPD=""
    if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
        TMPD="${TMPDIR:-/tmp}/benchy_ult.$$"
        mkdir -p "$TMPD" 2>/dev/null || { err "Cannot create a temp directory"; exit 1; }
    fi
    if sleep 0.01 2>/dev/null; then POLL=0.01; else POLL=1; fi
}

cleanup() {
    local p
    p=$(jobs -p 2>/dev/null)
    # shellcheck disable=SC2086
    [ -n "$p" ] && kill $p 2>/dev/null
    [ -n "$SHM_FILE" ] && rm -f "$SHM_FILE" 2>/dev/null
    [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null
    return 0
}

print_system_info() {
    section "SYSTEM"
    printf '  %-12s %s\n' "Host:" "$HOST"
    printf '  %-12s %s\n' "OS:" "$OS_PRETTY"
    printf '  %-12s %s\n' "Arch:" "$ARCH"
    printf '  %-12s %s (%s logical cores)\n' "CPU:" "$CPU_MODEL" "$CORES"
    if [ "$MEM_TOTAL_MB" -gt 0 ]; then printf '  %-12s %s MB\n' "Memory:" "$MEM_TOTAL_MB"; fi
    printf '  %-12s %s\n' "Bash:" "$BASH_VERSION"
    printf '  %-12s %s | %s\n' "Tools:" "$AWK_FLAVOR" "$DD_FLAVOR"
    printf '  %-12s %s\n' "Clock:" "$CLOCK"
    printf '  %-12s %s trials x ~%ss per test\n' "Plan:" "$TRIALS" "$TRIAL_SECS"
    [ -n "$LOAD1" ] && printf '  %-12s %s\n' "Load (1m):" "$LOAD1"

    if [ -n "$LOAD1" ] && awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{exit !(l > c*0.3 + 0.5)}'; then
        warn "The machine is already busy (load $LOAD1). Results will be lower and noisier."
    fi
    if [ "$CLOCK" = "date-s" ]; then
        warn "Only a 1-second clock is available; stretching trials to 10 s for accuracy."
    fi
}

# =============================================================================
#  Measurement harness
# =============================================================================
TRIAL_US=0 CAL_MIN_US=0 _WORK=0 _SINK=0 RATES="" BENCH_N=0
ST_MED=0 ST_SPREAD=0

setup_timing() {
    TRIAL_US=$(awk -v s="$TRIAL_SECS" 'BEGIN{printf "%d", s*1000000}')
    if [ "$CLOCK" = "date-s" ] && [ "$TRIAL_US" -lt 10000000 ]; then TRIAL_US=10000000; fi
    CAL_MIN_US=$((TRIAL_US / 4))
    [ "$CAL_MIN_US" -lt 200000 ] && CAL_MIN_US=200000
    [ "$CLOCK" = "date-s" ] && CAL_MIN_US=3000000
    return 0
}

dots() { printf '%s.%s' "$C_GRY" "$C_RST"; }

# Unit functions take N, do N units of work, and set _ELAPSED_US and _WORK.
# run_bench FN START_N : calibrate (warmup, discarded), then TRIALS timed runs.
run_bench() {
    local fn=$1 n=$2 tries=0 f
    while :; do
        "$fn" "$n" || return 1
        [ "$_ELAPSED_US" -ge "$CAL_MIN_US" ] && break
        tries=$((tries + 1))
        [ "$tries" -ge 40 ] && return 1
        if [ "$_ELAPSED_US" -le 0 ]; then
            f=10
        else
            f=$(( (CAL_MIN_US * 3 / 2) / _ELAPSED_US + 1 ))
            [ "$f" -lt 2 ] && f=2
            [ "$f" -gt 16 ] && f=16
        fi
        n=$((n * f))
    done
    dots
    BENCH_N=$(awk -v n="$n" -v e="$_ELAPSED_US" -v t="$TRIAL_US" \
        'BEGIN{x=int(n*t/e+0.5); if(x<1)x=1; printf "%d", x}')
    run_fixed "$fn" "$BENCH_N"
}

# run_fixed FN N : TRIALS timed runs of exactly N units.
run_fixed() {
    local fn=$1 n=$2 i=0 bad=0 r
    RATES=""
    while [ "$i" -lt "$TRIALS" ]; do
        "$fn" "$n" || return 1
        if [ "$_ELAPSED_US" -le 0 ]; then       # wall clock stepped backwards
            bad=$((bad + 1)); [ "$bad" -gt 3 ] && return 1
            continue
        fi
        r=$(awk -v w="$_WORK" -v e="$_ELAPSED_US" 'BEGIN{printf "%.6f", w*1000000/e}')
        RATES="$RATES $r"
        i=$((i + 1))
        dots
    done
    return 0
}

# stats "r1 r2 ..." -> ST_MED ST_MIN ST_MAX ST_SPREAD (spread = (max-min)/median %)
stats() {
    local out
    # shellcheck disable=SC2086
    out=$(printf '%s\n' $1 | sort -n | awk '
        { v[NR] = $1 }
        END {
            if (NR == 0) { print "0 0 0 0"; exit }
            if (NR % 2) m = v[(NR + 1) / 2]; else m = (v[NR / 2] + v[NR / 2 + 1]) / 2
            sp = (m > 0) ? (v[NR] - v[1]) / m * 100 : 0
            printf "%.6f %.6f %.6f %.2f\n", m, v[1], v[NR], sp
        }')
    # shellcheck disable=SC2086
    set -- $out
    ST_MED=$1 ST_SPREAD=$4
}

fmt_int() {   # 1234567.8 -> 1,234,568
    awk -v x="$1" 'BEGIN{
        s = sprintf("%.0f", x); neg = (substr(s,1,1) == "-"); if (neg) s = substr(s,2)
        o = ""; while (length(s) > 3) { o = "," substr(s, length(s)-2) o; s = substr(s, 1, length(s)-3) }
        printf "%s%s%s", (neg ? "-" : ""), s, o }'
}

noise_tag() {
    if awk -v s="$1" 'BEGIN{exit !(s > 10)}'; then
        printf '%s(+/-%s%%, noisy)%s' "$C_YEL" "$1" "$C_RST"
    else
        printf '%s(+/-%s%%)%s' "$C_GRY" "$1" "$C_RST"
    fi
}

# =============================================================================
#  CPU tests
# =============================================================================
# One "op" = one loop iteration of an integer multiply, add and modulo,
# executed by bash itself. No external commands run inside the loop.
cpu_spin() {
    local n=$1 i x=1
    for ((i = 0; i < n; i++)); do
        ((x = (x * 7 + 3) % 1000003))
    done
    _SINK=$x
    return 0
}

u_cpu() {
    t_start
    cpu_spin "$1"
    t_stop
    _WORK=$1
    return 0
}

# Aggregate throughput = sum of each worker's own rate. Every worker waits on
# a start barrier and times itself, so one straggler (a noisy neighbour on a
# VM, a late fork on Windows) can't drag the whole number down the way
# "total work / slowest worker" would.
u_cpu_multi() {
    local n=$1 i=0 go="$TMPD/go"
    rm -f "$go" "$TMPD"/w.*
    while [ "$i" -lt "$CORES" ]; do
        (
            while [ ! -f "$go" ]; do sleep "$POLL" 2>/dev/null || sleep 1; done
            t_start
            cpu_spin "$n"
            t_stop
            echo "$_ELAPSED_US" > "$TMPD/w.$i"
            exit 0
        ) &
        i=$((i + 1))
    done
    : > "$go"          # start barrier: every worker begins at once
    wait
    # The harness computes rate = _WORK / _ELAPSED_US, so report the summed
    # rate over a nominal one second.
    _WORK=$(cat "$TMPD"/w.* 2>/dev/null | awk -v n="$n" -v c="$CORES" '
        $1 > 0 { r += n * 1000000 / $1; k++ }
        END { if (k == c) printf "%.0f", r; else print 0 }')
    _ELAPSED_US=1000000
    [ "${_WORK:-0}" != 0 ] || return 1
    return 0
}

SINGLE=0 SINGLE_SP=0 MULTI=0 MULTI_SP=0 SCALING=0

cpu_tests() {
    section "CPU"
    printf '  %-28s ' "Single-core (bash int ops)"
    if ! run_bench u_cpu 2000; then printf '\n'; err "Single-core test failed"; return 1; fi
    stats "$RATES"; SINGLE=$ST_MED; SINGLE_SP=$ST_SPREAD
    printf ' %s%s%s ops/s %s\n' "$C_B" "$(fmt_int "$SINGLE")" "$C_RST" "$(noise_tag "$SINGLE_SP")"

    printf '  %-28s ' "Multi-core  ($CORES workers)"
    # Short warmup so every core has ramped its clock before timing.
    u_cpu_multi $((BENCH_N / 8 + 1)) >/dev/null 2>&1
    dots
    if ! run_fixed u_cpu_multi "$BENCH_N"; then printf '\n'; err "Multi-core test failed"; return 1; fi
    stats "$RATES"; MULTI=$ST_MED; MULTI_SP=$ST_SPREAD
    printf ' %s%s%s ops/s %s\n' "$C_B" "$(fmt_int "$MULTI")" "$C_RST" "$(noise_tag "$MULTI_SP")"

    SCALING=$(awk -v m="$MULTI" -v s="$SINGLE" -v c="$CORES" 'BEGIN{printf "%.1f", (s>0)? m/(s*c)*100 : 0}')
    printf '  %-28s  %s%% of perfect (%sx speedup on %s cores)\n' "Scaling" "$SCALING" \
        "$(awk -v m="$MULTI" -v s="$SINGLE" 'BEGIN{printf "%.2f", (s>0)? m/s : 0}')" "$CORES"
}

# =============================================================================
#  Memory tests: a cascade, each result sanity-checked before it is accepted
#    1. dd        /dev/zero -> /dev/null with 256 MiB (or 64 MiB) blocks.
#                 Pure RAM fill, no filesystem, works on Linux/macOS/MSYS/BSD.
#    2. tmpfs     write a file in /dev/shm, only if it really is tmpfs (Linux).
#    3. awk       in-process string copies (32 MiB), no device files at all.
#    4. powershell  .NET buffer copy via powershell.exe. Windows/WSL only, and
#                 only when 1-3 all fail (or when forced with -m powershell).
# =============================================================================
MEM_BS=0 SHM_MB=0 AWK_HALF=16777216 PS_BIN="" PS_BLOCK_MB=""
MEM_USED="none" MEM_DESC="" MEM_RATE=0 MEM_SP=0 MEM_LOG=""
MEM_MIN_MIBS=20 MEM_MAX_MIBS=4000000

forced_fail() {
    case " $FORCE_FAIL " in *" $1 "*) return 0 ;; esac
    return 1
}

dd_bytes() {   # parse "<N> bytes ..." from dd's stderr; fall back to expected
    local b
    b=$(printf '%s\n' "$1" | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^bytes/ {b = $1} END {printf "%.0f", b + 0}')
    if is_digits "$b" && [ "$b" -gt 0 ]; then echo "$b"; else echo "$2"; fi
}

u_mem_dd() {
    local n=$1 out rc
    t_start
    out=$(dd if=/dev/zero of=/dev/null bs="$MEM_BS" count="$n" 2>&1)
    rc=$?
    t_stop
    [ "$rc" -eq 0 ] || return 1
    _WORK=$(dd_bytes "$out" $((n * MEM_BS)))
    return 0
}

mem_try_dd() {
    if [ ! -r /dev/zero ] || [ ! -w /dev/null ]; then MEM_LOG="$MEM_LOG dd:no-dev-zero"; return 1; fi
    local bs list="268435456 67108864"
    [ "$MEM_TOTAL_MB" -gt 0 ] && [ "$MEM_TOTAL_MB" -lt 2048 ] && list="67108864"
    for bs in $list; do
        MEM_BS=$bs
        if u_mem_dd 1 && run_bench u_mem_dd 1; then
            MEM_DESC="dd fill, /dev/zero -> /dev/null, $((bs / 1048576)) MiB blocks"
            return 0
        fi
        MEM_LOG="$MEM_LOG dd:${bs}B-failed"
    done
    return 1
}

u_mem_tmpfs() {
    local n=$1 i=0
    t_start
    while [ "$i" -lt "$n" ]; do
        if ! dd if=/dev/zero of="$SHM_FILE" bs=1048576 count="$SHM_MB" 2>/dev/null; then
            t_stop; return 1
        fi
        i=$((i + 1))
    done
    t_stop
    _WORK=$((n * SHM_MB * 1048576))
    return 0
}

mem_try_tmpfs() {
    if [ "$OS_KIND" != linux ] && [ "$OS_KIND" != wsl ]; then MEM_LOG="$MEM_LOG tmpfs:not-linux"; return 1; fi
    if ! awk '$2 == "/dev/shm" && $3 == "tmpfs" {f = 1} END {exit !f}' /proc/mounts 2>/dev/null; then
        MEM_LOG="$MEM_LOG tmpfs:no-tmpfs-at-/dev/shm"; return 1
    fi
    local avail_kb
    avail_kb=$(df -Pk /dev/shm 2>/dev/null | awk 'NR == 2 {print $4}')
    is_digits "$avail_kb" || avail_kb=0
    SHM_MB=$((avail_kb / 1024 / 4))
    [ "$SHM_MB" -gt 256 ] && SHM_MB=256
    if [ "$SHM_MB" -lt 16 ]; then MEM_LOG="$MEM_LOG tmpfs:too-small(${avail_kb}KB)"; return 1; fi
    SHM_FILE=$(mktemp /dev/shm/benchy_ult.XXXXXX 2>/dev/null) || SHM_FILE=""
    if [ -z "$SHM_FILE" ]; then MEM_LOG="$MEM_LOG tmpfs:not-writable"; return 1; fi
    if run_bench u_mem_tmpfs 1; then
        rm -f "$SHM_FILE"; SHM_FILE=""
        MEM_DESC="tmpfs write, /dev/shm, $SHM_MB MiB file"
        return 0
    fi
    rm -f "$SHM_FILE"; SHM_FILE=""
    MEM_LOG="$MEM_LOG tmpfs:write-failed"
    return 1
}

u_mem_awk() {
    local n=$1 out rc
    t_start
    out=$(awk -v n="$n" -v half="$AWK_HALF" 'BEGIN {
            s = "0123456789abcdef"; t = 0
            while (length(s) < half) { s = s s; t += length(s) }
            for (i = 0; i < n; i++) { u = s s; t += length(u) }
            printf "%.0f\n", t
        }' 2>/dev/null)
    rc=$?
    t_stop
    [ "$rc" -eq 0 ] && is_digits "$out" && [ "$out" != 0 ] || return 1
    _WORK=$out
    return 0
}

mem_try_awk() {
    if run_bench u_mem_awk 1; then
        MEM_DESC="awk in-process string copy, $((AWK_HALF * 2 / 1048576)) MiB strings"
        return 0
    fi
    MEM_LOG="$MEM_LOG awk:failed"
    return 1
}

find_powershell() {
    local c root
    for c in powershell.exe pwsh.exe pwsh; do
        if command -v "$c" >/dev/null 2>&1; then PS_BIN=$c; return 0; fi
    done
    root=""
    if [ -n "${SYSTEMROOT:-}" ] && command -v cygpath >/dev/null 2>&1; then
        root=$(cygpath -u "$SYSTEMROOT" 2>/dev/null) || root=""
    fi
    for c in "$root/System32/WindowsPowerShell/v1.0/powershell.exe" \
             /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
             /cygdrive/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
             /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
        if [ -f "$c" ]; then PS_BIN=$c; return 0; fi
    done
    return 1
}

# Windows-only last resort. Runs entirely inside PowerShell/.NET, so it does
# not depend on Cygwin's /dev emulation, /dev/shm, /proc/meminfo or disk.
# Passed with -Command (not -File), so script execution policy doesn't apply.
# No double quotes inside, so Windows command-line quoting can't mangle it.
PS_SCRIPT=$(cat <<'PSEOF'
$ErrorActionPreference='Stop'; $inv=[Globalization.CultureInfo]::InvariantCulture; $done=$false; foreach ($mb in 256,64) { try { $n=$mb*1048576; $a=New-Object byte[] $n; $b=New-Object byte[] $n; [Buffer]::BlockCopy($a,0,$b,0,$n); for ($t=0; $t -lt @TRIALS@; $t++) { $sw=[Diagnostics.Stopwatch]::StartNew(); $c=0; do { [Buffer]::BlockCopy($a,0,$b,0,$n); $c++ } while ($sw.Elapsed.TotalSeconds -lt @SECS@); $sw.Stop(); [Console]::Out.WriteLine('RATE '+(($c*$n)/$sw.Elapsed.TotalSeconds).ToString('F0',$inv)) }; [Console]::Out.WriteLine('BLOCK '+$mb); $done=$true; break } catch { $a=$null; $b=$null; [GC]::Collect() } }; if (-not $done) { exit 3 }
PSEOF
)

mem_try_powershell() {
    if [ "$MEM_METHOD" = auto ] && [ "$OS_KIND" != windows ] && [ "$OS_KIND" != wsl ]; then
        MEM_LOG="$MEM_LOG powershell:not-windows"; return 1
    fi
    if ! find_powershell; then MEM_LOG="$MEM_LOG powershell:not-found"; return 1; fi
    local secs script out
    secs=$(awk -v t="$TRIAL_US" 'BEGIN{printf "%.2f", t/1000000}')
    script=${PS_SCRIPT//@TRIALS@/$TRIALS}
    script=${script//@SECS@/$secs}
    out=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
          "$PS_BIN" -NoLogo -NoProfile -NonInteractive -Command "$script" 2>/dev/null | tr -d '\r')
    RATES=$(printf '%s\n' "$out" | awk '$1 == "RATE" && $2 ~ /^[0-9]+$/ {printf " %s", $2}')
    PS_BLOCK_MB=$(printf '%s\n' "$out" | awk '$1 == "BLOCK" {print $2}')
    if [ -z "$RATES" ]; then MEM_LOG="$MEM_LOG powershell:failed"; return 1; fi
    MEM_DESC=".NET buffer copy via PowerShell, ${PS_BLOCK_MB:-?} MiB blocks"
    return 0
}

mem_tests() {
    section "MEMORY"
    local order m mibs
    if [ "$MEM_METHOD" = auto ]; then order="dd tmpfs awk powershell"; else order=$MEM_METHOD; fi
    for m in $order; do
        printf '  %-28s ' "Trying $m"
        if forced_fail "$m"; then
            MEM_LOG="$MEM_LOG $m:forced-fail"; printf '%sskipped (forced)%s\n' "$C_GRY" "$C_RST"; continue
        fi
        RATES=""
        if ! "mem_try_$m"; then
            printf '%sunavailable%s %s\n' "$C_GRY" "$C_RST" "${MEM_LOG##* }"
            continue
        fi
        stats "$RATES"
        mibs=$(awk -v r="$ST_MED" 'BEGIN{printf "%.1f", r/1048576}')
        if awk -v x="$mibs" -v lo="$MEM_MIN_MIBS" -v hi="$MEM_MAX_MIBS" 'BEGIN{exit !(x >= lo && x <= hi)}'; then
            MEM_USED=$m MEM_RATE=$mibs MEM_SP=$ST_SPREAD
            MEM_LOG="$MEM_LOG $m:ok"
            printf ' %s%s%s MiB/s %s\n' "$C_B" "$(fmt_int "$MEM_RATE")" "$C_RST" "$(noise_tag "$MEM_SP")"
            printf '  %-28s  %s\n' "Method" "$MEM_DESC"
            return 0
        fi
        MEM_LOG="$MEM_LOG $m:implausible(${mibs}MiB/s)"
        printf ' %simplausible result (%s MiB/s), trying next method%s\n' "$C_YEL" "$mibs" "$C_RST"
    done
    MEM_USED=none
    err "Every memory method failed:${MEM_LOG}"
    return 1
}

# =============================================================================
#  Legacy (v1-scale) scores, so old minibench.sh results stay comparable
#  v1 counted loop passes in 60 s, and each pass forked `date`, so its CPU
#  number mostly measures process-spawn speed. These replicate v1 exactly,
#  over 5 s windows scaled to 60 s for the CPU part.
# =============================================================================
LEG_CPU="" LEG_MEM="" LEG_NOTE=""

legacy_worker() {
    local secs=$1 start end count=0 x=1 y=7 z=3
    start=$(date +%s%N)
    end=$((start + secs * 1000000000))
    while [ "$(date +%s%N)" -lt "$end" ]; do
        x=$(( (x * y + z) % 1000000 ))
        count=$((count + 1))
    done
    echo "$count"
}

legacy_tests() {
    [ "$LEGACY" -eq 1 ] || return 0
    section "LEGACY (v1 scale)"
    if [ "$DATE_NS_OK" -ne 1 ]; then
        LEG_NOTE="needs GNU date +%N, like v1"
        warn "Skipped: $LEG_NOTE (v1 itself can't run here)"
        return 0
    fi
    printf '  %-28s ' "v1 CPU loop (${LEGACY_SECS}s)"
    local i=0 total=0 c
    while [ "$i" -lt "$CORES" ]; do
        legacy_worker "$LEGACY_SECS" > "$TMPD/leg.$i" &
        i=$((i + 1))
    done
    wait
    i=0
    while [ "$i" -lt "$CORES" ]; do
        c=$(cat "$TMPD/leg.$i" 2>/dev/null)
        is_digits "$c" && total=$((total + c))
        i=$((i + 1))
    done
    LEG_CPU=$(awk -v t="$total" -v s="$LEGACY_SECS" 'BEGIN{printf "%.2f", t*60/s/1000}')
    printf ' CPU Score %s%s%s\n' "$C_B" "$LEG_CPU" "$C_RST"

    printf '  %-28s ' "v1 simple mem (5s)"
    if ! dd if=/dev/zero of="$TMPD/fdtest" bs=1 count=1 conv=fdatasync 2>/dev/null; then
        LEG_NOTE="dd lacks conv=fdatasync"
        printf 'skipped (%s)\n' "$LEG_NOTE"
        return 0
    fi
    local f bytes=0 start end
    f=$(mktemp /dev/shm/simple_memtest.XXXXXX 2>/dev/null) || f="$TMPD/simple_memtest"
    start=$(date +%s%N); end=$((start + 5000000000))
    while [ "$(date +%s%N)" -lt "$end" ]; do
        dd if=/dev/zero of="$f" bs=1048576 count=8 conv=fdatasync 2>/dev/null || break
        bytes=$((bytes + 8 * 1048576))
    done
    rm -f "$f"
    LEG_MEM=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576/5/1000*100}')
    printf ' Memory Score %s%s%s\n' "$C_B" "$LEG_MEM" "$C_RST"
}

# =============================================================================
#  Scores, dashboard, files
# =============================================================================
SC_SINGLE="" SC_MULTI="" SC_MEM="" SC_ALL=""

score_of() {   # score_of VALUE REF -> 1000 * value/ref, or empty
    [ -n "$2" ] || return 0
    awk -v v="$1" -v r="$2" 'BEGIN{ if (r > 0 && v > 0) printf "%.0f", v / r * 1000 }'
}

calc_scores() {
    SC_SINGLE=$(score_of "$SINGLE" "$REF_SINGLE")
    SC_MULTI=$(score_of "$MULTI" "$REF_MULTI")
    SC_MEM=""
    if [ "$MEM_USED" != none ]; then
        local ref
        eval "ref=\${REF_MEM_$MEM_USED:-}"
        SC_MEM=$(score_of "$MEM_RATE" "$ref")
    fi
    SC_ALL=$(awk -v a="$SC_SINGLE" -v b="$SC_MULTI" -v c="$SC_MEM" 'BEGIN{
        n = 0; s = 0
        if (a > 0) { s += log(a); n++ }
        if (b > 0) { s += log(b); n++ }
        if (c > 0) { s += log(c); n++ }
        if (n) printf "%.0f", exp(s / n) }' 2>/dev/null)
    if [ -z "$SC_ALL" ]; then   # awk built without log/exp (some BusyBox builds)
        SC_ALL=$(awk -v a="$SC_SINGLE" -v b="$SC_MULTI" -v c="$SC_MEM" 'BEGIN{
            n = (a > 0) + (b > 0) + (c > 0); if (n) printf "%.0f", (a + b + c) / n }')
    fi
}

bar() {   # bar SCORE -> 30-char bar, full at 2000
    local s=${1:-0} w=30 f
    f=$(awk -v s="$s" -v w="$w" 'BEGIN{x = int(s / 2000 * w + 0.5); if (x > w) x = w; if (x < 0) x = 0; print x}')
    local full empty
    full=$(printf '%*s' "$f" '' | tr ' ' '#')
    empty=$(printf '%*s' $((w - f)) '' | tr ' ' '-')
    printf '%s[%s%s%s%s%s]%s' "$C_GRY" "$C_CYN" "$full" "$C_GRY" "$empty" "$C_GRY" "$C_RST"
}

score_row() {   # score_row LABEL SCORE
    if [ -n "$2" ]; then
        printf '  %-14s %s %s%6s%s\n' "$1" "$(bar "$2")" "$C_B" "$2" "$C_RST"
    else
        printf '  %-14s %sn/a%s\n' "$1" "$C_GRY" "$C_RST"
    fi
}

print_dashboard() {
    section "RESULTS"
    printf '  %-26s %16s ops/s  %s\n' "CPU single-core" "$(fmt_int "$SINGLE")" "$(noise_tag "$SINGLE_SP")"
    printf '  %-26s %16s ops/s  %s\n' "CPU multi-core" "$(fmt_int "$MULTI")" "$(noise_tag "$MULTI_SP")"
    printf '  %-26s %15s%%\n' "CPU scaling" "$SCALING"
    if [ "$MEM_USED" != none ]; then
        printf '  %-26s %16s MiB/s  %s\n' "Memory ($MEM_USED)" "$(fmt_int "$MEM_RATE")" "$(noise_tag "$MEM_SP")"
    else
        printf '  %-26s %16s\n' "Memory" "FAILED"
    fi
    printf '\n  %sScores (1000 = reference 4-vCPU Xeon cloud VM; higher is better)%s\n' "$C_DIM" "$C_RST"
    score_row "Single-core" "$SC_SINGLE"
    score_row "Multi-core" "$SC_MULTI"
    score_row "Memory" "$SC_MEM"
    printf '  %s\n' "$(printf '%*s' 52 '' | tr ' ' '-')"
    if [ -n "$SC_ALL" ]; then
        printf '  %s%s%-14s%s %s %s%s%6s%s\n' "$C_B" "$C_MAG" "ULT SCORE" "$C_RST" "$(bar "$SC_ALL")" "$C_B" "$C_YEL" "$SC_ALL" "$C_RST"
    fi
    if [ "$MEM_USED" = powershell ] && [ -z "$SC_MEM" ]; then
        printf '  %sMemory score: no reference for the PowerShell method yet; MiB/s is still valid.%s\n' "$C_GRY" "$C_RST"
    fi
    if [ -n "$LEG_CPU$LEG_MEM" ]; then
        printf '\n  %sv1-compatible (compare with old minibench.sh runs; NOT the same units as above)%s\n' "$C_DIM" "$C_RST"
        printf '  %-26s %s\n' "v1 CPU Score" "${LEG_CPU:-n/a}"
        printf '  %-26s %s\n' "v1 Memory Score" "${LEG_MEM:-n/a}"
    fi
    if awk -v a="$SINGLE_SP" -v b="$MULTI_SP" -v c="$MEM_SP" 'BEGIN{exit !(a > 10 || b > 10 || c > 10)}'; then
        printf '\n'
        warn "Some results varied more than 10% between trials. Close other apps, plug in power,"
        warn "and try --thorough for steadier numbers."
    fi
}

write_results() {
    local now out="$RESULT_FILE" dir
    now=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)
    dir=$(dirname "$out")
    if [ ! -w "$dir" ]; then out="${TMPDIR:-/tmp}/$(basename "$out")"; fi
    {
        echo "benchy_version=$BENCHY_VERSION"
        echo "date=$now"
        echo "host=$HOST"
        echo "os=$OS_PRETTY"
        echo "arch=$ARCH"
        echo "cpu=$CPU_MODEL"
        echo "cores=$CORES"
        echo "mem_total_mb=$MEM_TOTAL_MB"
        echo "bash=$BASH_VERSION"
        echo "awk=$AWK_FLAVOR"
        echo "clock=$CLOCK"
        echo "trials=$TRIALS"
        echo "trial_secs=$TRIAL_SECS"
        echo "cpu_single_ops_per_sec=$(awk -v x="$SINGLE" 'BEGIN{printf "%.0f", x}')"
        echo "cpu_single_spread_pct=$SINGLE_SP"
        echo "cpu_multi_ops_per_sec=$(awk -v x="$MULTI" 'BEGIN{printf "%.0f", x}')"
        echo "cpu_multi_spread_pct=$MULTI_SP"
        echo "cpu_scaling_pct=$SCALING"
        echo "mem_method=$MEM_USED"
        echo "mem_method_detail=$MEM_DESC"
        echo "mem_mib_per_sec=$MEM_RATE"
        echo "mem_spread_pct=$MEM_SP"
        echo "mem_attempts=${MEM_LOG# }"
        echo "score_single=$SC_SINGLE"
        echo "score_multi=$SC_MULTI"
        echo "score_mem=$SC_MEM"
        echo "score_ult=$SC_ALL"
        echo "v1_cpu_score=$LEG_CPU"
        echo "v1_mem_score=$LEG_MEM"
    } > "$out" 2>/dev/null && ok "Results saved to $out"

    [ "$WRITE_HISTORY" -eq 1 ] || return 0
    local h="$HISTORY_FILE"
    [ -w "$(dirname "$h")" ] || return 0
    if [ ! -f "$h" ]; then
        echo "date,host,os,cpu,cores,bash,single_ops,multi_ops,mem_method,mem_mibs,score_single,score_multi,score_mem,score_ult,v1_cpu,v1_mem" > "$h"
    fi
    printf '%s,%s,"%s","%s",%s,%s,%.0f,%.0f,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$now" "$HOST" "$OS_PRETTY" "$CPU_MODEL" "$CORES" "$BASH_VERSION" \
        "$SINGLE" "$MULTI" "$MEM_USED" "$MEM_RATE" \
        "$SC_SINGLE" "$SC_MULTI" "$SC_MEM" "$SC_ALL" "$LEG_CPU" "$LEG_MEM" >> "$h" 2>/dev/null \
        && ok "Run appended to $h"
}

# =============================================================================
#  Main
# =============================================================================
main() {
    parse_args "$@"
    setup_color
    trap cleanup EXIT
    trap 'printf "\n"; warn "Interrupted"; exit 130' INT TERM
    print_banner
    clock_init
    detect_system
    make_tmpdir
    setup_timing
    print_system_info

    local t0 rc=0
    t0=$(date +%s)
    cpu_tests || rc=1
    mem_tests || rc=1
    legacy_tests
    calc_scores
    print_dashboard
    printf '\n'
    write_results
    printf '  %sFinished in %ss.%s\n\n' "$C_GRY" $(( $(date +%s) - t0 )) "$C_RST"
    return "$rc"
}

main "$@"
