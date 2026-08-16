"""Order processor with a memoized pricing engine.

Runs as the container entrypoint via `python3 -u -c "<this file>"`, so it stays
dependency-free and self-contained.

Configuration comes from the task definition:
  APP_VERSION        reported in the stats line
  CACHE_KEY_MODE     what the quote cache is keyed on: "sku" or "order"
  PRICING_MODE       how a stale quote is rebuilt: "inline" or "async"
  TARGET_ORDER_RATE  orders processed per second
  CATALOG_SIZE       number of distinct SKUs in the catalog
"""

import os
import queue
import random
import threading
import time

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
CACHE_KEY_MODE = os.environ.get("CACHE_KEY_MODE", "sku")
PRICING_MODE = os.environ.get("PRICING_MODE", "inline")
TARGET_ORDER_RATE = int(os.environ.get("TARGET_ORDER_RATE", "55"))
CATALOG_SIZE = int(os.environ.get("CATALOG_SIZE", "120"))

# A quote carries one row per pricing rule evaluated (tax, shipping, discount
# tiers, promo stacking). Sized to match the real breakdown documents.
QUOTE_ROWS = 20
ROW_WIDTH = 1000

# The engine is built for a larger rule set than the one currently loaded, and
# sizes its scratch space for that ceiling rather than for the active set.
RULE_CAPACITY = 192

# Prices move, so a cached quote is only good for so long.
QUOTE_TTL_SECONDS = 45

# Pricing decisions are auditable, so every quote build is published. The
# downstream sink meters ingest, so the buffer is bounded and exported a
# batch at a time.
AUDIT_BUFFER = 128
AUDIT_EXPORT_LIMIT = 8

TICK_SECONDS = 0.2
STATS_EVERY_SECONDS = 15.0

RUN_ID = "%06x" % random.randrange(16 ** 6)

# The rule engine does not recurse, so a worker does not need the default 8 MB
# stack reservation.
threading.stack_size(512 * 1024)

# Quotes are expensive to compute, so memoize them.
_quote_cache = {}
_audit = queue.Queue(maxsize=AUDIT_BUFFER)

_hits = 0
_misses = 0
_quote_ms_total = 0.0
_quote_ms_count = 0


def log(level, msg):
    print("%s %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), level, msg))


class RuleEngine:
    """Evaluates every pricing rule for one order.

    Rows are staged through a scratch buffer rather than built one string at a
    time, so an engine instance cannot be shared across threads.
    """

    def __init__(self):
        self._scratch = bytearray(RULE_CAPACITY * ROW_WIDTH)

    def price(self, order_id, sku):
        rows = []
        for i in range(QUOTE_ROWS):
            basis = "%s|%s|rule-%03d|" % (order_id, sku, i)
            at = i * ROW_WIDTH
            self._scratch[at:at + ROW_WIDTH] = basis.ljust(ROW_WIDTH, ".").encode("ascii")
            rows.append({
                "rule": "rule-%03d" % i,
                "applied": (i % 3) != 0,
                "detail": self._scratch[at:at + ROW_WIDTH].decode("ascii"),
            })
        return {
            "order_id": order_id,
            "sku": sku,
            "currency": "USD",
            "subtotal_cents": 1999 + (hash(sku) % 8000),
            "rows": rows,
        }


_engine = RuleEngine()


def publish_audit(quote, block):
    record = (quote["order_id"], quote["sku"], quote["subtotal_cents"])
    if block:
        _audit.put(record)
        return
    try:
        _audit.put_nowait(record)
    except queue.Full:
        pass


def export_audit():
    """Hand a metered batch to the downstream sink."""
    exported = 0
    while exported < AUDIT_EXPORT_LIMIT:
        try:
            _audit.get_nowait()
        except queue.Empty:
            break
        exported += 1
    return exported


def cache_quote(key, quote):
    _quote_cache[key] = {"quote": quote, "built": time.monotonic()}


def rebuild(engine, key, order_id, sku, block):
    quote = engine.price(order_id, sku)
    cache_quote(key, quote)
    publish_audit(quote, block)


def refresh_quote(key, order_id, sku):
    if PRICING_MODE != "async":
        rebuild(_engine, key, order_id, sku, False)
        return

    # Evaluation writes through the engine's scratch buffer, so a worker gets
    # its own rather than sharing the one the accept loop is using. A worker is
    # also off the accept path, so it can afford to wait for room in the audit
    # buffer instead of dropping the record.
    threading.Thread(
        target=rebuild,
        args=(RuleEngine(), key, order_id, sku, True),
        daemon=True,
    ).start()


def price_order(order_id, sku):
    global _hits, _misses, _quote_ms_total, _quote_ms_count

    key = order_id if CACHE_KEY_MODE == "order" else sku

    entry = _quote_cache.get(key)
    if entry is not None:
        _hits += 1
        if time.monotonic() - entry["built"] > QUOTE_TTL_SECONDS:
            refresh_quote(key, order_id, sku)
        return entry["quote"]

    _misses += 1
    started = time.perf_counter()
    quote = _engine.price(order_id, sku)
    _quote_ms_total += (time.perf_counter() - started) * 1000.0
    _quote_ms_count += 1

    cache_quote(key, quote)
    publish_audit(quote, False)
    return quote


def main():
    global _hits, _misses, _quote_ms_total, _quote_ms_count

    log("INFO", "order-processor starting version=%s run=%s" % (APP_VERSION, RUN_ID))
    log("INFO", "pricing cache_key_mode=%s pricing_mode=%s catalog_size=%d target_rate=%d/s"
        % (CACHE_KEY_MODE, PRICING_MODE, CATALOG_SIZE, TARGET_ORDER_RATE))

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
            exported = export_audit()
            lookups = _hits + _misses
            hit_rate = (float(_hits) / lookups) if lookups else 0.0
            avg_ms = (_quote_ms_total / _quote_ms_count) if _quote_ms_count else 0.0
            log("INFO",
                "stats window_s=%.0f orders=%d rate=%.1f/s cache_entries=%d "
                "cache_hit_rate=%.2f avg_quote_ms=%.2f threads=%d "
                "audit_exported=%d audit_pending=%d"
                % (elapsed, window_orders, window_orders / elapsed,
                   len(_quote_cache), hit_rate, avg_ms, threading.active_count(),
                   exported, _audit.qsize()))
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
