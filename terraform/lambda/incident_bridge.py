"""Forward any EventBridge event to an AWS DevOps Agent webhook.

This is a transport, not an interpreter. It does not know what an ECS task is,
what an exit code means, or which events are worth investigating. The
EventBridge rule decides what arrives; the agent decides what it means. Adding a
new signal - health check failures, crashes, latency, error rates - is a new rule
pointing at this same function, with no code change here.

Signing contract (matches aws-samples/sample-aws-devops-agent-cloudwatch):
    signature = base64(HMAC-SHA256(secret, "<timestamp>:<payload_json>"))
    headers   = x-amzn-event-signature, x-amzn-event-timestamp
The signed bytes must be byte-identical to the bytes sent, so the payload is
serialized exactly once and reused.
"""

import base64
import datetime
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request

import boto3

SECRET_ARN = os.environ["SECRET_ARN"]
DEFAULT_PRIORITY = os.environ.get("DEFAULT_PRIORITY", "HIGH")
PLACEHOLDER = "REPLACE_ME"

_secrets = boto3.client("secretsmanager")


def iso_millis():
    # Match the JavaScript reference implementation's Date.toISOString() shape.
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000)


def load_webhook():
    raw = _secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
    data = json.loads(raw)
    url, secret = data.get("webhookUrl"), data.get("webhookSecret")
    if not url or not secret or PLACEHOLDER in (url, secret):
        raise RuntimeError(
            "Webhook credentials are still placeholders. Run scripts/setup-webhook.sh."
        )
    return url, secret


def short(arn):
    """Last path or colon segment of an ARN, for human-readable labels."""
    if not arn:
        return "unknown"
    tail = arn.rsplit("/", 1)[-1]
    return tail if tail != arn else arn.rsplit(":", 1)[-1]


def incident_id(event):
    """Stable dedupe key.

    The agent opens one investigation per incidentId, so this must be identical
    across repeats of the same problem and different across distinct problems.
    Hashing the affected resources gives that generically: an alarm keeps its
    ARN while flapping, so it dedupes. A crash loop gets a new task ARN each
    restart, so each death is its own incident - the agent links them itself
    rather than us guessing at the grouping.
    """
    parts = [
        event.get("source", ""),
        event.get("detail-type", ""),
        "|".join(sorted(event.get("resources") or [])),
    ]
    digest = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]
    return "eventbridge-%s" % digest


def describe(event):
    """Render the event for a reader who has not been told what it means."""
    resources = event.get("resources") or []
    lines = [
        "An AWS EventBridge event was delivered for this account.",
        "",
        "Source:      %s" % event.get("source", "unknown"),
        "Detail type: %s" % event.get("detail-type", "unknown"),
        "Event time:  %s" % event.get("time", "unknown"),
        "Account:     %s" % event.get("account", "unknown"),
        "Region:      %s" % event.get("region", "unknown"),
    ]
    if resources:
        lines.append("Resources:")
        lines.extend("  %s" % r for r in resources)
    lines += [
        "",
        "Full event:",
        "```json",
        json.dumps(event, indent=2, sort_keys=True, default=str),
        "```",
        "",
        "Determine what this event indicates about the health of the affected "
        "resources, establish the underlying cause, and recommend a remediation.",
    ]
    return "\n".join(lines)


def post(url, secret, payload):
    timestamp = iso_millis()
    # Serialize once: these exact bytes are both signed and sent.
    body = json.dumps(payload, separators=(",", ":"), default=str).encode("utf-8")
    signed = ("%s:" % timestamp).encode("utf-8") + body
    signature = base64.b64encode(
        hmac.new(secret.encode("utf-8"), signed, hashlib.sha256).digest()
    ).decode("ascii")

    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-amzn-event-signature": signature,
            "x-amzn-event-timestamp": timestamp,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")


def handler(event, context):
    print("received event: %s" % json.dumps(event, default=str))

    detail_type = event.get("detail-type") or event.get("source") or "Event"
    resources = event.get("resources") or []
    label = short(resources[0]) if resources else event.get("account", "")

    payload = {
        "eventType": "incident",
        "incidentId": incident_id(event),
        "action": "created",
        "priority": DEFAULT_PRIORITY,
        "title": "%s: %s" % (detail_type, label) if label else detail_type,
        "description": describe(event),
        # The agent anchors on this to find the resource in its topology graph.
        # Passed as a full ARN rather than a guessed short name: which ARN
        # segment holds the "service" differs per resource type (cluster for an
        # ECS task, target group for an ELB target, the tail for an alarm), and
        # guessing wrong anchors it to the wrong thing.
        "service": resources[0] if resources else event.get("source", "aws"),
        "timestamp": iso_millis(),
        # Semantics of this object are undocumented, so the raw event goes here
        # and is also rendered into the description above, on the assumption the
        # agent reads the prose.
        "data": {"metadata": {"event": event}},
    }

    url, secret = load_webhook()
    status, text = post(url, secret, payload)

    print("webhook responded status=%s body=%s" % (status, text))
    if status >= 300:
        raise RuntimeError("webhook rejected the incident: %s %s" % (status, text))

    return {"status": status, "incidentId": payload["incidentId"]}
