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

    # User
    [ -n "$USER" ] && echo "User:       $USER"

    # Directory
    if dir=$(pwd 2>/dev/null); then
        [ -n "$dir" ] && echo "Directory:  $dir"
    fi

    # Hostname
    if host=$(hostname 2>/dev/null); then
        [ -n "$host" ] && echo "Hostname:   $host"
    fi

    # OS
    os_name=$(uname -s 2>/dev/null)
    os_version=$(uname -r 2>/dev/null)
    arch=$(uname -m 2>/dev/null)
    if [ -n "$os_name" ] && [ -n "$os_version" ] && [ -n "$arch" ]; then
        echo "OS:         $os_name $os_version ($arch)"
    fi

    # CPU info
    if [ -f /proc/cpuinfo ]; then  
        model=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')  
        cores=$(nproc 2>/dev/null)  
        [ -n "$model" ] && [ -n "$cores" ] && echo "CPU:        $model ($cores cores)"
    else  
        echo "CPU:        Unknown"  
    fi  

    # Memory info
    if [ -f /proc/meminfo ]; then  
        mem_total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)  
        [ -n "$mem_total_mb" ] && echo "Memory:     ${mem_total_mb} MB"
    fi  

    # Disk info
    if root_disk=$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " free"}'); then
        [ -n "$root_disk" ] && echo "Disk (/):   $root_disk"
    fi

    # Bash version
    [ -n "$BASH_VERSION" ] && echo "Bash:       $BASH_VERSION"

    # Uptime
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

mem_bench() {  
    echo "[MEM] Running benchmark for ${DURATION}s..."  
    if [ -f /proc/meminfo ]; then
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

        local mbps=$(printf "%.2f" "$(awk "BEGIN {print $total_bytes/1024/1024/$DURATION}")")  
        printf "[MEM] Average throughput over %d sec → %s MB/sec\n" "$DURATION" "$mbps"  
        MEM_RESULT="$mbps"  

        rm -f /dev/shm/memtest  
    else
        echo "[MEM] /proc/meminfo not found, skipping memory benchmark"
        MEM_RESULT="N/A"
    fi
}  

print_dashboard() {  
    echo  
    echo "############### BENCHMARK RESULTS ##########################"  
    echo " "  
    printf "Single-core CPU: %s thousand ops/sec\n" "$SINGLE_RESULT"  
    printf "Multi-core CPU:  %s thousand ops/sec\n" "$MULTI_RESULT"  
    printf "Memory:          %s MB/sec\n" "$MEM_RESULT"  
    echo " "  
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