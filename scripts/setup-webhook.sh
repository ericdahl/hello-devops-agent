#!/usr/bin/env bash
# Create the DevOps Agent event channel and store its webhook credentials.
#
# The webhook secret is returned ONLY in the associate-service response - not by
# get-association, not by update-association, and not by list-webhooks (which
# returns the URL alone). So the association has to be created and captured in a
# single step, which is why this is a script rather than Terraform: awscc would
# create the association fine but the secret would never reach Terraform state.
#
# Re-running this replaces the event channel and issues a fresh secret.
#
# Usage: AWS_PROFILE=your-profile ./scripts/setup-webhook.sh

set -euo pipefail

cd "$(dirname "$0")/../terraform"

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
SPACE_ID=$(terraform output -raw agent_space_id)
SECRET_ID=$(terraform output -raw webhook_secret_id)

export AWS_PAGER=""

# Remove any existing event channel so we get a secret we can actually capture.
EXISTING=$(aws devops-agent list-associations \
  --agent-space-id "$SPACE_ID" --region "$REGION" \
  --query "associations[?serviceId=='event_channel'].associationId" --output text)

for id in $EXISTING; do
  echo "removing existing event channel $id"
  aws devops-agent disassociate-service \
    --agent-space-id "$SPACE_ID" --association-id "$id" --region "$REGION" >/dev/null
done

echo "creating event channel..."
RESPONSE=$(aws devops-agent associate-service \
  --agent-space-id "$SPACE_ID" \
  --service-id event_channel \
  --configuration '{"eventChannel":{}}' \
  --region "$REGION")

# The secret goes straight from the response into Secrets Manager; it is never
# echoed to the terminal or left in a file.
SECRET_ID="$SECRET_ID" REGION="$REGION" python3 -c '
import json, os, subprocess, sys

data = json.loads(sys.stdin.read())
webhook = data.get("webhook") or {}
url, secret = webhook.get("webhookUrl"), webhook.get("webhookSecret")

if not (url and secret):
    sys.exit("associate-service did not return webhook credentials; check the response shape")

print("  association: %s" % data["association"]["associationId"])
print("  webhookUrl : %s" % url)
print("  secret     : %d chars captured" % len(secret))

subprocess.run([
    "aws", "secretsmanager", "put-secret-value",
    "--secret-id", os.environ["SECRET_ID"],
    "--region", os.environ["REGION"],
    "--secret-string", json.dumps({"webhookUrl": url, "webhookSecret": secret}),
], check=True, stdout=subprocess.DEVNULL)
print("  stored in Secrets Manager")
' <<<"$RESPONSE"

echo "done - the bridge Lambda can now reach the webhook"
