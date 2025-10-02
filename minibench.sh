#!/usr/bin/env bash

DURATION=60   # seconds to run each CPU test
RESULT_FILE="benchmark_results.txt"

# ASCII Art banner
print_banner() {
cat << 'EOF'
____ ____ ____     ___  ____ _  _ ____ _  _ 
[__  |__| [__      |__] |___ |\ | |    |__| 
___] |  | ___] ___ |__] |___ | \| |___ |  | 
                                            
  CPU & Memory Benchmark Script
#################################################################
EOF
}

# System info summary
print_system_info() {
    echo
    echo "############### SYSTEM INFO ###############"
    echo "User:       $USER"
    echo "Directory:  $(pwd)"
    echo "Hostname:   $(hostname)"
    echo "OS:         $(uname -s) $(uname -r) ($(uname -m))"

    # CPU info
    if [ -f /proc/cpuinfo ]; then
        local model=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
        local cores=$(nproc)
        echo "CPU:        $model ($cores cores)"
    else
        echo "CPU:        Unknown"
    fi

    # Memory info
    if [ -f /proc/meminfo ]; then
        local mem_total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
        echo "Memory:     ${mem_total_mb} MB"
    fi

    # Disk info
    local root_disk=$(df -h / | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " free"}')
    echo "Disk (/):   $root_disk"

    # Bash & uptime
    echo "Bash:       $BASH_VERSION"
    echo "Uptime:     $(uptime -p)"
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
    local kops=$(echo "scale=2; $ops / 1000" | bc)
    printf "[CPU] Single-core → %.2f thousand ops/sec\n" "$kops"
    SINGLE_RESULT="$kops"
}

cpu_multi() {
    local cores=$(nproc)
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

    local kops=$(echo "scale=2; $total / 1000" | bc)
    printf "[CPU] Multi-core → %.2f thousand ops/sec (all %d cores)\n" "$kops" "$cores"
    MULTI_RESULT="$kops"

    rm -rf "$tmpdir"
}

mem_bench() {
    echo "[MEM] Running benchmark for ${DURATION}s..."
    local total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local mb=$(( total_mem_mb / 2 ))
    echo "[MEM] Using $mb MB per iteration"

    mkdir -p /dev/shm
    local start_ns=$(date +%s%N)
    local end_ns=$((start_ns + DURATION * 1000000000))
    local total_bytes=0

    while [ $(date +%s%N) -lt $end_ns ]; do
        dd if=/dev/zero of=/dev/shm/memtest bs=1M count=$mb conv=fdatasync status=none
        total_bytes=$((total_bytes + mb * 1024 * 1024))
    done

    local mbps=$(echo "scale=2; $total_bytes / 1024 / 1024 / $DURATION" | bc -l)
    printf "[MEM] Average throughput over %d sec → %.2f MB/sec\n" "$DURATION" "$mbps"
    MEM_RESULT="$mbps"

    rm -f /dev/shm/memtest
}

print_dashboard() {
    echo
    echo "############### BENCHMARK RESULTS ##########################"
    printf "Single-core CPU: %.2f thousand ops/sec\n" "$SINGLE_RESULT"
    printf "Multi-core CPU:  %.2f thousand ops/sec\n" "$MULTI_RESULT"
    printf "Memory:          %.2f MB/sec\n" "$MEM_RESULT"
    echo "#################################################################"
}

write_results_file() {
    {
        echo "Single-test: $SINGLE_RESULT"
        echo "Multi-test: $MULTI_RESULT"
        echo "Mem-test: $MEM_RESULT"
    } > "$RESULT_FILE"
    echo "[INFO] Results saved to $RESULT_FILE"
}

# MAIN
print_banner
print_system_info
cpu_single
cpu_multi
mem_bench
print_dashboard
write_results_file