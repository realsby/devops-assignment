"""
External-ish uptime check for the portal. Runs on its own EventBridge
Scheduler schedule (see uptime.tf), hits the portal's Function URL over
plain HTTPS the same way a real user's browser would, and emits an EMF
log line -- no library, same trick as notifier/notifier.py's emf_log.

Caveat, on purpose, not fixed here: this check runs inside AWS (as a
Lambda, in the same region as the thing it's checking), so a full AWS
region outage would take both the portal and this check down together
-- silence, not an alert. An external checker (a different provider
entirely, e.g. a free-tier uptime service hitting the same URL from
outside AWS) is the honest next step; this is the "basic, not perfect"
version.
"""
import json
import os
import time
import urllib.error
import urllib.request

PORTAL_URL = os.environ["PORTAL_URL"]


def handler(event, context):  # noqa: ARG001 - Lambda calling convention
    url = f"{PORTAL_URL.rstrip('/')}/healthz"
    start = time.monotonic()
    up = 0
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            up = 1 if resp.status == 200 else 0
    except urllib.error.URLError as exc:
        print(
            json.dumps({"level": "error", "event": "uptime_check_failed", "error": str(exc)}),
            flush=True,
        )
    latency_ms = int((time.monotonic() - start) * 1000)

    # flush=True: stdout is block-buffered once it's not a terminal (see
    # notifier/notifier.py's emf_log for how this was actually found —
    # without it, lines can sit unflushed in Python's internal buffer).
    # A single-invocation function like this one is at lower risk than
    # notifier's long-running loop, but there's no reason to trust that
    # instead of just flushing.
    print(
        json.dumps(
            {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {
                            "Namespace": "WellisStatus",
                            "Dimensions": [[]],
                            "Metrics": [
                                {"Name": "Uptime", "Unit": "None"},
                                {"Name": "LatencyMs", "Unit": "Milliseconds"},
                            ],
                        }
                    ],
                },
                "Uptime": up,
                "LatencyMs": latency_ms,
            }
        ),
        flush=True,
    )

    return {"up": up, "latency_ms": latency_ms}
