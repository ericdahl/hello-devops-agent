"""Order processor with a memoized pricing engine.

Runs as the container entrypoint via `python3 -u -c "<this file>"`, so it stays
dependency-free and self-contained.

Configuration comes from the task definition:
  APP_VERSION        reported in the stats line
  CACHE_KEY_MODE     what the quote cache is keyed on: "sku" or "order"
  TARGET_ORDER_RATE  orders processed per second
  CATALOG_SIZE       number of distinct SKUs in the catalog
"""

import os
import random
import time

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
CACHE_KEY_MODE = os.environ.get("CACHE_KEY_MODE", "sku")
TARGET_ORDER_RATE = int(os.environ.get("TARGET_ORDER_RATE", "55"))
CATALOG_SIZE = int(os.environ.get("CATALOG_SIZE", "120"))

# A quote carries one row per pricing rule evaluated (tax, shipping, discount
# tiers, promo stacking). Sized to match the real breakdown documents.
QUOTE_ROWS = 20
ROW_WIDTH = 1000

TICK_SECONDS = 0.2
STATS_EVERY_SECONDS = 15.0

RUN_ID = "%06x" % random.randrange(16 ** 6)

# Quotes are expensive to compute, so memoize them.
_quote_cache = {}

_hits = 0
_misses = 0
_quote_ms_total = 0.0
_quote_ms_count = 0


def log(level, msg):
    print("%s %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), level, msg))


def build_quote(order_id, sku):
    """Evaluate every pricing rule and return the full breakdown document."""
    rows = []
    for i in range(QUOTE_ROWS):
        basis = "%s|%s|rule-%03d|" % (order_id, sku, i)
        rows.append({
            "rule": "rule-%03d" % i,
            "applied": (i % 3) != 0,
            "detail": basis.ljust(ROW_WIDTH, "."),
        })
    return {
        "order_id": order_id,
        "sku": sku,
        "currency": "USD",
        "subtotal_cents": 1999 + (hash(sku) % 8000),
        "rows": rows,
    }


def price_order(order_id, sku):
    global _hits, _misses, _quote_ms_total, _quote_ms_count

    key = order_id if CACHE_KEY_MODE == "order" else sku

    quote = _quote_cache.get(key)
    if quote is not None:
        _hits += 1
        return quote

    _misses += 1
    started = time.perf_counter()
    quote = build_quote(order_id, sku)
    _quote_ms_total += (time.perf_counter() - started) * 1000.0
    _quote_ms_count += 1

    _quote_cache[key] = quote
    return quote


def main():
    global _hits, _misses, _quote_ms_total, _quote_ms_count

    log("INFO", "order-processor starting version=%s run=%s" % (APP_VERSION, RUN_ID))
    log("INFO", "pricing cache_key_mode=%s catalog_size=%d target_rate=%d/s"
        % (CACHE_KEY_MODE, CATALOG_SIZE, TARGET_ORDER_RATE))

    per_tick = max(1, int(round(TARGET_ORDER_RATE * TICK_SECONDS)))
    orders = 0
    window_orders = 0
    last_stats = time.monotonic()

    while True:
        tick_started = time.monotonic()

        for _ in range(per_tick):
            orders += 1
            window_orders += 1
            order_id = "ord-%s-%08d" % (RUN_ID, orders)
            sku = "SKU-%04d" % random.randrange(CATALOG_SIZE)
            quote = price_order(order_id, sku)

            if orders % 500 == 0:
                log("INFO", "order accepted id=%s sku=%s subtotal=%d"
                    % (order_id, sku, quote["subtotal_cents"]))

        now = time.monotonic()
        elapsed = now - last_stats
        if elapsed >= STATS_EVERY_SECONDS:
            lookups = _hits + _misses
            hit_rate = (float(_hits) / lookups) if lookups else 0.0
            avg_ms = (_quote_ms_total / _quote_ms_count) if _quote_ms_count else 0.0
            log("INFO",
                "stats window_s=%.0f orders=%d rate=%.1f/s cache_entries=%d "
                "cache_hit_rate=%.2f avg_quote_ms=%.2f"
                % (elapsed, window_orders, window_orders / elapsed,
                   len(_quote_cache), hit_rate, avg_ms))
            window_orders = 0
            last_stats = now
            _hits = _misses = 0
            _quote_ms_total = 0.0
            _quote_ms_count = 0

        slack = TICK_SECONDS - (time.monotonic() - tick_started)
        if slack > 0:
            time.sleep(slack)


if __name__ == "__main__":
    main()
