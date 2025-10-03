MiniBench

![Badge Label](https://img.shields.io/badge/System-Benchmark-ff69b4) ![Badge Label](https://img.shields.io/badge/Bash-Script-green) ![Badge Label](https://img.shields.io/badge/License-Free-brightgreen)

A beautiful and efficient bash script that benchmarks your system's CPU and memory performance with stunning visual output! ✨
🎯 What This Script Does

This amazing script performs comprehensive system benchmarking:

    🎵 Single-Core CPU Test - Measures raw single-threaded performance

    🚀 Multi-Core CPU Test - Leverages all available CPU cores simultaneously

    💾 Memory Benchmark - Tests memory write throughput with intelligent fallbacks

    📊 System Info - Displays comprehensive hardware and OS information

🛠 Features That Sparkle

    ✨ ASCII Art Banner

    🖥 Complete System Information

    🎯 Smart Memory Allocation with automatic fallbacks

    ⏱ Configurable Test Duration

    💾 Results Export to text file

    🛡 Error Handling with graceful failure recovery

    🎪 Colorful Visual Output

🚀 Quick Start
Prerequisites

    Linux system with /proc filesystem

    Bash shell

    Basic utilities: awk, dd, mktemp

Installation & Usage
```
# Download the script
curl -O https://raw.githubusercontent.com/your-repo/benchmark.sh

# Make it executable
chmod +x benchmark.sh

# Run the benchmark!
./benchmark.sh
```

One-liner Installation


```
curl -sL https://raw.githubusercontent.com/your-repo/benchmark.sh | bash
```

⚙️ Configuration

Easily customize the benchmark duration by editing the DURATION variable:

```
DURATION=120   # Change this to run longer tests (in seconds)
```
📈 Understanding Results

    Single-Core CPU: Higher is better! Measures computational speed per core

    Multi-Core CPU: Shows parallel processing capability across all cores

    Memory Throughput: Indicates RAM write speed in MB/second

🎪 Technical Highlights
Smart Memory Allocation

The script intelligently handles memory allocation with multiple fallback levels:

    45% of Total Memory (primary attempt)

    45% of Available Memory (first fallback)

    50% of Free Memory (final fallback)

Robust Error Handling
```

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO"; exit 1' ERR
```

Clean Temporary Management

Uses mktemp for safe temporary file handling and automatic cleanup.
🤝 Contributing

Love this script? Want to make it even more amazing? Contributions are welcome!

Feel free to:

    🐛 Report bugs

    💡 Suggest new features

    🔧 Submit pull requests

    ⭐ Star the repository

📜 License

This project is completely FREE! 🎉

Do whatever you want with it - use, modify, distribute, no restrictions! Happy benchmarking! 🚀
🎊 Final Words

```
This script brings joy and sparkle to system benchmarking! Whether you're testing new hardware, comparing systems, or just satisfying your inner geek, this tool makes performance testing a delightful experience.
```

Go forth and benchmark all the things! 🌟

Made with 💝 and bash magic
