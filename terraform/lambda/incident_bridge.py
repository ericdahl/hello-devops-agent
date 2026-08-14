"""Bridge EventBridge events into an AWS DevOps Agent webhook.

DevOps Agent has no native EventBridge or CloudWatch alarm target, so this
function translates events into the webhook's incident schema and signs them.

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
            "Webhook credentials are still placeholders. Create the webhook in the "
            "DevOps Agent web app, then run the put-secret-value command from "
            "`terraform output -raw set_webhook_command`."
        )
    return url, secret


def short(arn):
    return arn.rsplit("/", 1)[-1] if arn else "unknown"


def from_ecs_task(event):
    """ECS Task State Change -> incident."""
    d = event.get("detail", {})
    cluster = short(d.get("clusterArn"))
    task_id = short(d.get("taskArn"))
    task_def = short(d.get("taskDefinitionArn"))
    group = d.get("group", "")
    service = group.split(":", 1)[1] if group.startswith("service:") else group
    reason = d.get("stoppedReason", "unknown")
    stop_code = d.get("stopCode", "unknown")

    containers = []
    for c in d.get("containers", []):
        containers.append(
            {
                "name": c.get("name"),
                "exitCode": c.get("exitCode"),
                "reason": c.get("reason"),
            }
        )

    oom = "outofmemory" in reason.lower() or any(
        "outofmemory" in (c.get("reason") or "").lower() for c in containers
    )
    headline = "OOM-killed" if oom else "stopped unexpectedly"

    description = "\n".join(
        [
            'ECS task %s in service "%s" %s.' % (task_id, service, headline),
            "",
            "Cluster:         %s" % cluster,
            "Service:         %s" % service,
            "Task definition: %s" % task_def,
            "Stop code:       %s" % stop_code,
            "Stopped reason:  %s" % reason,
            "Started at:      %s" % d.get("startedAt", "unknown"),
            "Stopped at:      %s" % d.get("stoppedAt", "unknown"),
            "Containers:      %s" % json.dumps(containers),
            "",
            "The service scheduler will replace the task, so expect a restart loop "
            "until the underlying cause is fixed. Investigate recent task definition "
            "revisions and deployments for this service, and correlate container "
            "memory usage against the task memory limit.",
        ]
    )

    return {
        # Stable per task, so a replay of the same event dedupes rather than
        # opening a second investigation.
        "incidentId": "ecs-task-stopped-%s" % task_id,
        "priority": "HIGH" if oom else "MEDIUM",
        "title": "ECS task %s in %s (%s)" % (headline, service, cluster),
        "description": description,
        "service": service or cluster,
        "metadata": {
            "signal": "ecs-task-state-change",
            "cluster_arn": d.get("clusterArn"),
            "task_arn": d.get("taskArn"),
            "task_definition_arn": d.get("taskDefinitionArn"),
            "service_name": service,
            "stop_code": stop_code,
            "stopped_reason": reason,
            "containers": containers,
            "region": event.get("region"),
            "account": event.get("account"),
        },
    }


def from_alarm(event):
    """CloudWatch Alarm State Change -> incident."""
    d = event.get("detail", {})
    name = d.get("alarmName", "unknown")
    state = d.get("state", {})
    reason = state.get("reason", "no reason provided")

    description = "\n".join(
        [
            'CloudWatch alarm "%s" entered %s.' % (name, state.get("value", "ALARM")),
            "",
            "Reason: %s" % reason,
            "Region: %s" % event.get("region"),
            "",
            "This is a leading indicator: memory is climbing but the task has not "
            "been killed yet. Check whether utilization is trending up steadily "
            "rather than spiking, which would suggest retention rather than load.",
        ]
    )

    return {
        # Bucket by minute so a flapping alarm does not open an investigation per flap.
        "incidentId": "alarm-%s-%s" % (name, event.get("time", "")[:16]),
        "priority": "MEDIUM",
        "title": "CloudWatch alarm: %s" % name,
        "description": description,
        "service": name,
        "metadata": {
            "signal": "cloudwatch-alarm",
            "alarm_name": name,
            "alarm_arn": d.get("alarmArn") or event.get("resources", [None])[0],
            "state": state.get("value"),
            "reason": reason,
            "region": event.get("region"),
            "account": event.get("account"),
        },
    }


def post(url, secret, payload):
    timestamp = iso_millis()
    # Serialize once: these exact bytes are both signed and sent.
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
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
    print("received event: %s" % json.dumps(event))
    detail_type = event.get("detail-type")

    if detail_type == "ECS Task State Change":
        incident = from_ecs_task(event)
    elif detail_type == "CloudWatch Alarm State Change":
        incident = from_alarm(event)
    else:
        print("ignoring unsupported detail-type: %s" % detail_type)
        return {"status": "ignored", "detailType": detail_type}

    payload = {
        "eventType": "incident",
        "incidentId": incident["incidentId"],
        "action": "created",
        "priority": incident["priority"],
        "title": incident["title"],
        "description": incident["description"],
        "service": incident["service"],
        "timestamp": iso_millis(),
        "data": {"metadata": incident["metadata"]},
    }

    url, secret = load_webhook()
    status, body = post(url, secret, payload)
    print("webhook responded status=%s body=%s" % (status, body))

    if status >= 300:
        raise RuntimeError("webhook rejected the incident: %s %s" % (status, body))

    return {"status": status, "incidentId": payload["incidentId"]}
