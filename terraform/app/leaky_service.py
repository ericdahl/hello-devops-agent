"""Mock order-processing service with an optional memory leak.

Runs as the container entrypoint via `python3 -u -c "<this file>"`, so it must
stay dependency-free and self-contained.

Behaviour is driven entirely by env vars set in the task definition:
  APP_VERSION      cosmetic, but it lands in CloudTrail as a task-def diff
  LEAK_MB_PER_MIN  0 = healthy. >0 retains memory until the container is killed.
  MEM_LIMIT_MB     the container hard limit, used only to log headroom warnings
"""

import os
import sys
import time

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
LEAK_MB_PER_MIN = float(os.environ.get("LEAK_MB_PER_MIN", "0"))
MEM_LIMIT_MB = float(os.environ.get("MEM_LIMIT_MB", "400"))

TICK_SECONDS = 5.0
LEAK_MB_PER_TICK = LEAK_MB_PER_MIN * (TICK_SECONDS / 60.0)
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")

# Anything appended here is never freed - that is the whole point.
_retained = []


def rss_mb():
    # statm field 1 is resident set size in pages.
    with open("/proc/self/statm") as fh:
        return int(fh.read().split()[1]) * PAGE_SIZE / (1024 * 1024)


def log(level, msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print("%s %s %s" % (ts, level, msg))


def main():
    log("INFO", "starting order-processor version=%s pid=%d" % (APP_VERSION, os.getpid()))
    log("INFO", "config leak_mb_per_min=%.1f mem_limit_mb=%.0f" % (LEAK_MB_PER_MIN, MEM_LIMIT_MB))
    if LEAK_MB_PER_MIN <= 0:
        log("INFO", "no retention configured; steady state expected")

    started = time.monotonic()
    orders = 0
    warned = False

    while True:
        orders += 7
        if LEAK_MB_PER_TICK > 0:
            # bytearray is zero-filled, so these pages are actually resident.
            _retained.append(bytearray(int(LEAK_MB_PER_TICK * 1024 * 1024)))

        rss = rss_mb()
        uptime = time.monotonic() - started
        log(
            "INFO",
            "processed orders=%d uptime_s=%.0f rss_mb=%.1f cache_entries=%d"
            % (orders, uptime, rss, len(_retained)),
        )

        # A leading indicator the agent can find in the logs before the kill.
        if rss > MEM_LIMIT_MB * 0.7:
            if not warned:
                log("WARN", "heap above 70%% of container limit; GC pressure rising")
                warned = True
            log(
                "WARN",
                "memory headroom low rss_mb=%.1f limit_mb=%.0f pct=%.0f"
                % (rss, MEM_LIMIT_MB, 100.0 * rss / MEM_LIMIT_MB),
            )

        sys.stdout.flush()
        time.sleep(TICK_SECONDS)


if __name__ == "__main__":
    main()
