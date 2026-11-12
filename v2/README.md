# Benchy Ult (minibench v2)

One script, any machine with bash, numbers you can compare.

```
bash v2/benchy-ult.sh            # ~45 s: 5 trials x 2 s per test
bash v2/benchy-ult.sh --quick    # ~15 s
bash v2/benchy-ult.sh --thorough # ~2-3 min, steadiest numbers
bash v2/benchy-ult.sh -h         # every option
```

The v1 script (`minibench.sh`) is untouched. Benchy Ult also prints v1-scale
scores so old results stay comparable.

## What changed from v1

| | v1 `minibench.sh` | v2 `benchy-ult.sh` |
|---|---|---|
| CPU units | Loop passes per **60 s**, labelled "ops/sec" | Real ops per second |
| What the CPU test measured | Mostly how fast the OS can fork `date` (one fork per loop pass) | bash integer math; the clock is read only at the start and end of a trial |
| Timing | `date +%s%N` (GNU only, breaks on macOS) | `$EPOCHREALTIME` (no fork), then GNU date, perl, python3, 1 s clock |
| Repeatability | One 60 s run per test | Calibrated warmup, then N trials; median and spread reported, noisy runs flagged |
| Multi-core | Wall time of the slowest worker | Start barrier, each worker times itself, rates summed |
| Memory | Writes a file of 45% of RAM to `/dev/shm` | 256 MiB in-RAM fill; no huge allocations, no disk |
| Memory fallbacks | Retry the same method with smaller sizes | Four different methods, each result sanity-checked |
| Windows | `/dev/shm` is on disk, results swing (see below) | dd fill, then awk, then a PowerShell/.NET test only for Windows |
| Output | Fixed text | Colour gradient banner (plain when piped, `NO_COLOR`, or `--no-color`), score bars, results file + CSV history |
| Errors | `set -e` + ERR trap kills the run on the first odd exit code | Every step checked; one failed test doesn't stop the others; temp files always cleaned up |

## Scores

`1000` = the reference machine (4 vCPU Xeon cloud VM, bash 5.2). Twice as
fast scores 2000. The ULT SCORE is the geometric mean of single-core,
multi-core and memory.

The CPU test runs in bash, so the bash build matters a little (macOS ships
bash 3.2). The tools line in the output records bash/awk/dd versions for
that reason. Memory scores are per method: compare `dd` runs with `dd` runs.

## Memory cascade

Used in order; the first that works and gives a plausible number wins. The
output says which one ran.

1. **dd**: `/dev/zero -> /dev/null` with 256 MiB blocks (64 MiB on machines
   under 2 GB). Pure RAM fill, no filesystem. Linux, macOS, MSYS2, Cygwin, BSD.
2. **tmpfs**: write a file in `/dev/shm`, only when it really is a tmpfs
   (checked in `/proc/mounts`). Linux and WSL only.
3. **awk**: copies 32 MiB strings inside awk. No device files at all.
4. **powershell**: .NET `Buffer.BlockCopy` on 256 MiB arrays, run through
   `powershell.exe -Command`. Windows (Git Bash/MSYS2/Cygwin) and WSL only,
   and only when 1-3 all fail. Force it with `-m powershell`.

Test the cascade yourself: `BENCHY_FORCE_FAIL="dd awk" bash v2/benchy-ult.sh`
treats those methods as failed.

## Why v1's RAM tests fail on Windows, some runs and not others

From reading `minibench.sh`. "Code" means the code shows it; "Inferred" means
it depends on how Git Bash/MSYS2/Cygwin behave and wasn't run on Windows.

1. **`/dev/shm` isn't RAM on Windows.** (Inferred, high confidence.) Cygwin
   and MSYS2 implement `/dev/shm` as an ordinary folder on disk. So v1's
   "memory" test writes a file of 45% of RAM to disk, with `conv=fdatasync`
   forcing a flush every pass (Code). On a 16 GB laptop that's a 7 GB disk
   write per pass. Speed then depends on the disk, the cache and what else is
   running, which is why results swing.
2. **The run needs 45% of RAM in free disk space and write access.** (Code
   for the size; Inferred for the folder.) If the drive is short of space,
   or the folder is not writable (for example under `C:\Program Files\Git`
   without admin rights), every `dd` fails and the test reports N/A.
3. **`MemAvailable` is probably missing.** (Inferred.) Cygwin's
   `/proc/meminfo` has no `MemAvailable` line, so the first fallback computes
   an empty size and always fails (Code: `count=""` makes dd error out), and
   the script lands on 50% of `MemFree`. Windows' free-memory figure moves a
   lot from minute to minute, so the file size, and the result, changes run
   to run.
4. **Antivirus can lock the file between passes.** (Inferred.) Each pass
   rewrites the same multi-GB `memtest` file. If Windows Defender is still
   scanning it, the next `dd` can't open it, which ends the loop with
   "Memory write failed during iteration". That only happens when the timing
   lines up, so it looks random.
5. **The timing overruns and then divides by 60.** (Code.) The deadline is
   only checked between passes, and the bytes are divided by `DURATION`, not
   the real elapsed time. When one pass takes several seconds, whether 4 or
   5 passes fit in the window changes the result by 20% or more.
6. **The "simple" test is a disk test too.** (Code for the fallback;
   Inferred for Windows.) With no usable `/dev/shm` it writes to `/tmp`,
   which Git Bash maps to your Windows temp folder, again with a flush every
   8 MB. The v1 Memory Score comes from this test.

Benchy Ult avoids all of these: no `/dev/shm` on Windows, no file bigger than
256 MiB, no `/proc/meminfo` dependency, and a timed fixed amount of work.

## Files written

* `benchy_ult_results.txt`: key=value results of the last run (`-o FILE` to change).
* `benchy_ult_history.csv`: one row per run, for comparing machines (`--no-history` to skip).

## Tested

* Linux (Ubuntu 24.04, bash 5.2): every memory method, every clock source,
  gawk, mawk, one-true-awk and BusyBox awk/dd, `sh` re-exec, `NO_COLOR`,
  piped output, `shellcheck` clean.
* Windows paths: simulated (fake `uname` and `powershell.exe`) to check the
  cascade and the exact PowerShell command line. Not yet run on a real
  Windows machine.
* macOS: written for bash 3.2 and BSD tools, not yet run on a Mac.
