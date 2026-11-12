MiniBench

![Badge Label](https://img.shields.io/badge/System-Benchmark-ff69b4) ![Badge Label](https://img.shields.io/badge/Bash-Script-green) ![Badge Label](https://img.shields.io/badge/License-Free-brightgreen)

Benchy Ult: a beautiful, portable bash script that benchmarks your system's CPU and memory and gives you numbers you can actually compare, on any machine with bash! ✨
🎯 What This Script Does

This amazing script performs comprehensive system benchmarking:

    🎵 Single-Core CPU Test - 30 seconds of sustained integer math on one core

    🚀 Multi-Core CPU Test - 30 seconds of sustained load on every core at once

    💾 Memory Test - Measures RAM speed on one core, then on all cores together

    📊 System Info - Displays hardware, OS and tool information

🛠 Features That Sparkle

    ✨ Colour Gradient ASCII Art Banner (plain text when piped or with NO_COLOR)

    🖥 Runs Anywhere With Bash - Linux, macOS, Windows Git Bash/MSYS2/Cygwin, WSL, BSD

    🎯 Consistent Results - warmup, repeated trials, median and spread for every test

    ⏱ Configurable Test Duration

    💾 Simple Results File you can hand to anyone

    🛡 Error Handling - one failed test never stops the others

    🎪 Score Bars for every result

🚀 Quick Start
Prerequisites

    Any system with bash 3.2 or newer (Linux, macOS, Windows Git Bash, WSL, BSD)

    Basic utilities: awk, dd, mktemp

Installation & Usage
```
# Download the script
curl -O https://raw.githubusercontent.com/lewallen4/Minibench/main/minibench.sh

# Make it executable
chmod +x minibench.sh

# Run the benchmark!
./minibench.sh
```

One-liner Installation


```
curl -sL https://raw.githubusercontent.com/lewallen4/Minibench/main/minibench.sh -o minibench.sh && bash minibench.sh
```

⚙️ Configuration

A full run takes about 90 seconds. Change it with options:

```
./minibench.sh --quick        # ~15 seconds, 5 s CPU tests
./minibench.sh --thorough     # ~3 minutes, steadiest numbers
./minibench.sh -c 60          # 60 seconds per CPU test
./minibench.sh -o mypc.txt    # choose the results file name
./minibench.sh --no-color     # plain output
./minibench.sh -h             # every option
```
📈 Understanding Results

The results file (benchy_ult_results.txt) is short on purpose, so an engineer can run the benchmark and hand the file to anyone:

```
Benchy Ult v2.2.0
=================
Single-core: 533814 ops/sec
Multi-core: 2244527 ops/sec
Memory: 22870 MiB/sec
CPU-score: 1005
Memory-score: 986
Ult-score: 995
```

    Single-core / Multi-core: integer operations per second. Higher is better!

    Memory: MiB per second all cores can write to RAM together. Higher is better!

    Scores: 1000 = the reference machine (a 4-core Xeon cloud server). 2000 = twice as fast

    CPU-score: single-core and multi-core combined

    Memory-score: the all-cores memory result

    Ult-score: CPU and Memory combined, weighted equally. The one number to compare machines by

The terminal output has the full detail for engineers: how much each test varied between trials, the single-core memory speed, which memory method ran, and Classic scores on the original MiniBench scale.

🎪 Technical Highlights
Smart Memory Testing

The script picks the first memory method that works and gives a believable number:

    dd fill - /dev/zero to /dev/null in 256 MiB blocks, pure RAM, no disk (primary)

    tmpfs write - a file in /dev/shm, only where it really is RAM (Linux)

    awk copy - large string copies inside awk, no device files at all

    PowerShell - a .NET memory copy, Windows only, used only if everything else fails

No test ever allocates more than a quarter of your RAM.

Accurate Timing

The clock is read only at the start and end of each trial, never inside the measured loop. It uses bash's built-in clock when available, then GNU date, perl or python.

Clean Temporary Management

Uses mktemp for safe temporary file handling and automatic cleanup, even if you press Ctrl-C.
🤝 Contributing

Love this script? Want to make it even more amazing? Contributions are welcome!

Feel free to:

    🐛 Report bugs

    💡 Suggest new features

    🔧 Submit pull requests

    ⭐ Star the repository

📜 License

This project is completely FREE! 🎉

By downloading, installing, or using this Software, you hereby affirm to uphold truth, justice, equity, and the democratic ideals of the American way. You further acknowledge and agree to defend and respect the sovereignty, self-determination, and human rights of all peoples, including but not limited to those of Ukraine, Palestine, Taiwan, Hong Kong, Tibet, Sudan, and any nation or community striving toward freedom and dignity. You strive to uphold the right of every person to live authentically, free from discrimination or harm, regardless of race, creed, sexual orientation, or gender identity and expression. Use of this Software constitutes your pledge to counter oppression, misinformation, and authoritarianism in all forms, and to act in good faith toward a more just, accepting, tolerant and sustainable world.

🎊 Final Words

```
This script brings joy and sparkle to system benchmarking! Whether you're testing new hardware, comparing systems, or just satisfying your inner geek, this tool makes performance testing a delightful experience.
```

Go forth and benchmark all the things! 🌟

Made with 💝 and bash magic
