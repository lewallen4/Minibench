#!/usr/bin/env bash  

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO"; exit 1' ERR

DURATION=60   # seconds to run each CPU test  
RESULT_FILE="benchmark_results.txt"  
MEM_FALLBACKS=""  # Track any memory fallback messages

# Baselines (arbitrary reference for an "8-core 3GHz" system)
CPU_BASELINE=100000   # thousand ops/sec (multi-core)
MEM_BASELINE=1000    # MB/sec (simple mem)

CPU_SCORE=0
MEM_SCORE=0

# ASCII Art banner  
print_banner() {  
cat << 'EOF'  
#################################################################
____ ____ ____     ___  ____ _  _ ____ _  _   
[__  |__| [__      |__] |___ |\ | |    |__|   
___] |  | ___] ___ |__] |___ | \| |___ |  |   
                                              
  CPU & Memory Benchmark Script  
 
EOF
}  

# System info summary  
print_system_info() {  
    echo "############### SYSTEM INFO #####################################"  

    if USER=$(whoami 2>/dev/null); then [ -n "$USER" ] && echo "User:  $USER"; fi
    if dir=$(pwd 2>/dev/null); then [ -n "$dir" ] && echo "Directory:  $dir"; fi
    if host=$(hostname 2>/dev/null); then [ -n "$host" ] && echo "Hostname:   $host"; fi

    os_name=$(uname -s 2>/dev/null)
    os_version=$(uname -r 2>/dev/null)
    arch=$(uname -m 2>/dev/null)
    [ -n "$os_name" ] && [ -n "$os_version" ] && [ -n "$arch" ] && echo "OS:         $os_name $os_version ($arch)"

    if [ -f /proc/cpuinfo ]; then  
        model=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')  
        cores=$(nproc 2>/dev/null)  
        [ -n "$model" ] && [ -n "$cores" ] && echo "CPU:        $model ($cores cores)"
    else  
        echo "CPU:        Unknown"  
    fi  

    if [ -f /proc/meminfo ]; then  
        mem_total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)  
        [ -n "$mem_total_mb" ] && echo "Memory:     ${mem_total_mb} MB"
    fi  

    if root_disk=$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " free"}'); then
        [ -n "$root_disk" ] && echo "Disk (/):   $root_disk"
    fi

    [ -n "$BASH_VERSION" ] && echo "Bash:       $BASH_VERSION"

    if uptime_info=$(uptime -p 2>/dev/null); then
        [ -n "$uptime_info" ] && echo "Uptime:     $uptime_info"
    fi

    echo "#################################################################"  
    echo  
}  

cpu_worker() {  
    local start_ns=$(date +%s%N)  
    local end_ns=$((start_ns + DURATION * 1000000000))  
    local count=0  
    local x=1 y=7 z=3  

    while [ $(date +%s%N) -lt $end_ns ]; do  
        x=$(( (x * y + z) % 1000000 ))  
        count=$((count + 1))  
    done  

    echo "$count"  
}  

cpu_single() {  
    echo "[CPU] Single-core benchmark for ${DURATION}s..."  
    local ops=$(cpu_worker)  
    local kops=$(printf "%.2f" "$(echo "$ops / 1000" | awk '{printf "%f", $1}')")  
    printf "[CPU] Single-core → %s thousand ops/sec\n" "$kops"  
    SINGLE_RESULT="$kops"  
}  

cpu_multi() {  
    local cores=$(nproc 2>/dev/null)  
    echo "[CPU] Multi-core benchmark on $cores cores for ${DURATION}s..."  

    tmpdir=$(mktemp -d)  
    declare -a files  
    for ((i=0;i<cores;i++)); do  
        files[i]="$tmpdir/worker_$i.txt"  
        cpu_worker > "${files[i]}" &  
    done  

    wait  

    local total=0  
    for f in "${files[@]}"; do  
        total=$((total + $(cat "$f")))  
    done  

    local kops=$(printf "%.2f" "$(echo "$total / 1000" | awk '{printf "%f", $1}')")  
    printf "[CPU] Multi-core → %s thousand ops/sec (all %d cores)\n" "$kops" "$cores"  
    MULTI_RESULT="$kops"  

    rm -rf "$tmpdir"  
}  

# ----------------------------
# NEW SIMPLE CONTAINER-SAFE MEM TEST
# ----------------------------
mem_simple_bench() {
    echo "[MEM-SIMPLE] Running lightweight memory test (5s, container safe)..."
    local duration=5
    local start_ns=$(date +%s%N)
    local end_ns=$((start_ns + duration * 1000000000))
    local total_bytes=0
    local block_size=$((1024*1024)) # 1MB blocks
    local tmpfile=$(mktemp /dev/shm/simple_memtest.XXXXXX || echo "/tmp/simple_memtest.$$")

    while [ $(date +%s%N) -lt $end_ns ]; do
        if dd if=/dev/zero of="$tmpfile" bs=$block_size count=8 conv=fdatasync status=none 2>/dev/null; then
            total_bytes=$((total_bytes + 8 * block_size))
        else
            echo "[MEM-SIMPLE] Write failed, breaking."
            break
        fi
    done

    rm -f "$tmpfile"

    SIMPLE_MEM_RESULT=$(awk "BEGIN {print $total_bytes/1024/1024/$duration}")
    printf "[MEM-SIMPLE] Average throughput → %.2f MB/sec\n" "$SIMPLE_MEM_RESULT"
}

# ----------------------------
# ORIGINAL FULL MEMORY TEST
# ----------------------------
mem_bench() {  
    echo "[MEM] Running benchmark for ${DURATION}s..."  
    if [ ! -f /proc/meminfo ]; then
        echo "[MEM] /proc/meminfo not found, skipping memory benchmark"
        MEM_RESULT="N/A"
        return
    fi

    local mb=0
    MEM_FALLBACKS=""

    # Try 45% of total memory
    local total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    mb=$(( total_mem_mb * 45 / 100 ))
    echo "[MEM] Attempting to allocate $mb MB (45% of total memory)"

    mkdir -p /dev/shm || { echo "[ERROR] Cannot access /dev/shm"; MEM_RESULT="N/A"; return; }

    local start_ns=$(date +%s%N)
    local end_ns=$((start_ns + DURATION * 1000000000))
    local total_bytes=0

    while true; do
        if dd if=/dev/zero of=/dev/shm/memtest bs=1M count="$mb" conv=fdatasync status=none 2>/dev/null; then
            total_bytes=$((total_bytes + mb * 1024 * 1024))
            break
        else
            MEM_FALLBACKS="[WARN] 45% of MemTotal failed, trying 45% of MemAvailable"
            mb=$(awk '/MemAvailable/ {print int($2/1024*0.45)}' /proc/meminfo)
            if dd if=/dev/zero of=/dev/shm/memtest bs=1M count="$mb" conv=fdatasync status=none 2>/dev/null; then
                total_bytes=$((total_bytes + mb * 1024 * 1024))
                break
            else
                MEM_FALLBACKS="[WARN] MemAvailable failed, trying 50% of MemFree"
                mb=$(awk '/MemFree/ {print int($2/1024/2)}' /proc/meminfo)
                if dd if=/dev/zero of=/dev/shm/memtest bs=1M count="$mb" conv=fdatasync status=none 2>/dev/null; then
                    total_bytes=$((total_bytes + mb * 1024 * 1024))
                    break
                else
                    echo "[ERROR] Memory allocation failed at all fallback levels. Skipping memory benchmark."
                    MEM_RESULT="N/A"
                    MEM_FALLBACKS="[ERROR] All memory allocation attempts failed"
                    return
                fi
            fi
        fi
    done

    while [ $(date +%s%N) -lt $end_ns ]; do
        if ! dd if=/dev/zero of=/dev/shm/memtest bs=1M count="$mb" conv=fdatasync status=none 2>/dev/null; then
            echo "[WARN] Memory write failed during iteration, stopping loop"
            break
        fi
        total_bytes=$((total_bytes + mb * 1024 * 1024))
    done

    MEM_RESULT=$(awk "BEGIN {print $total_bytes/1024/1024/$DURATION}")
    printf "[MEM] Average throughput over %d sec → %.2f MB/sec\n" "$DURATION" "$MEM_RESULT"

    rm -f /dev/shm/memtest
}  

# ----------------------------
# SCORING FUNCTIONS
# ----------------------------
calc_cpu_score() {
    CPU_SCORE=$(awk -v r="$MULTI_RESULT" -v base="$CPU_BASELINE" 'BEGIN {printf "%.0f", (r/base)*100}')
}

calc_mem_score() {
    MEM_SCORE=$(awk -v r="$SIMPLE_MEM_RESULT" -v base="$MEM_BASELINE" 'BEGIN {printf "%.0f", (r/base)*100}')
}

print_dashboard() {  
    echo  
    echo "############### BENCHMARK RESULTS ###############################"  
    echo " "  
    printf "Single-core CPU: %s thousand ops/sec\n" "$SINGLE_RESULT"  
    printf "Multi-core CPU:  %s thousand ops/sec\n" "$MULTI_RESULT"  
    printf "Simple Memory:   %s MB/sec\n" "$SIMPLE_MEM_RESULT"  
    printf "Full Memory:     %s MB/sec\n" "$MEM_RESULT"  
    if [ -n "$MEM_FALLBACKS" ]; then
        echo "$MEM_FALLBACKS"
    fi
    echo " "  
    printf "CPU Score:       %d\n" "$CPU_SCORE"
    printf "Memory Score:    %d\n" "$MEM_SCORE"
    echo " "  
    echo "#################################################################"  
}  

write_results_file() {  
    {  
        echo "Single-test: $SINGLE_RESULT"  
        echo "Multi-test: $MULTI_RESULT"  
        echo "Simple-mem-test: $SIMPLE_MEM_RESULT"  
        echo "Mem-test: $MEM_RESULT"  
        echo "CPU-score: $CPU_SCORE"  
        echo "Mem-score: $MEM_SCORE"  
        [ -n "$MEM_FALLBACKS" ] && echo "$MEM_FALLBACKS"
    } > "$RESULT_FILE"  
    echo "[INFO] Results saved to $RESULT_FILE"  
}  

# MAIN  
print_banner  
print_system_info  
cpu_single  
cpu_multi  
mem_simple_bench  
mem_bench  
calc_cpu_score  
calc_mem_score  
print_dashboard  
write_results_file