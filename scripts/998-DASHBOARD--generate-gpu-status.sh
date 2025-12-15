#!/bin/bash
#===============================================================================
# 998-DASHBOARD--generate-gpu-status.sh
# Generates HTML dashboard of GPU status and uploads to S3
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Creates a static HTML dashboard showing:
#   - Currently running GPU resources (RunPod + AWS)
#   - Event history from last 24 hours
#   - Cost summary
#   - Activity timeline
#
# Uploads to S3 for easy viewing in a browser.
#
# USAGE:
#   ./scripts/998-DASHBOARD--generate-gpu-status.sh
#
# S3 CONFIGURATION:
#   Set GPU_DASHBOARD_S3_BUCKET in .env or environment
#   Default: s3://your-bucket/gpu-dashboard/
#
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/gpu-event-logger.sh" 2>/dev/null || true

# Load environment
ENV_FILE="$SCRIPT_DIR/../.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
S3_BUCKET="${GPU_DASHBOARD_S3_BUCKET:-}"
OUTPUT_DIR="$SCRIPT_DIR/../artifacts"
OUTPUT_FILE="$OUTPUT_DIR/gpu-dashboard.html"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

mkdir -p "$OUTPUT_DIR"

#===============================================================================
# Gather current state
#===============================================================================

get_runpod_status() {
    if [ -z "$RUNPOD_API_KEY" ]; then
        echo "[]"
        return
    fi

    curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        "https://rest.runpod.io/v1/pods" 2>/dev/null || echo "[]"
}

get_aws_gpu_status() {
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,pending,stopping" \
        --query "Reservations[*].Instances[*].{id:InstanceId,type:InstanceType,state:State.Name,launch:LaunchTime,name:Tags[?Key=='Name'].Value|[0]}" \
        --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
gpu_types = ['g4dn', 'g5', 'p3', 'p4d', 'p5', 'g3', 'g6']
result = []
for reservation in data:
    for inst in reservation:
        if any(gt in inst.get('type', '') for gt in gpu_types):
            result.append(inst)
print(json.dumps(result))
" 2>/dev/null || echo "[]"
}

RUNPOD_DATA=$(get_runpod_status)
AWS_DATA=$(get_aws_gpu_status)
EVENT_LOG="${GPU_EVENT_LOG:-$SCRIPT_DIR/../logs/gpu-events.jsonl}"

#===============================================================================
# Generate HTML
#===============================================================================

cat > "$OUTPUT_FILE" << 'HTMLHEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GPU Cost Guardian Dashboard</title>
    <meta http-equiv="refresh" content="300">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d1117;
            color: #c9d1d9;
            padding: 20px;
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 {
            color: #58a6ff;
            border-bottom: 1px solid #30363d;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        h2 {
            color: #8b949e;
            font-size: 14px;
            text-transform: uppercase;
            margin: 20px 0 10px;
        }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        .card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 6px;
            padding: 16px;
        }
        .card-title { color: #8b949e; font-size: 12px; }
        .card-value { color: #58a6ff; font-size: 28px; font-weight: bold; }
        .card-value.cost { color: #f85149; }
        .card-value.running { color: #3fb950; }
        .card-value.ok { color: #3fb950; }
        .resource-table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        .resource-table th, .resource-table td {
            padding: 10px 12px;
            text-align: left;
            border-bottom: 1px solid #30363d;
        }
        .resource-table th {
            background: #161b22;
            color: #8b949e;
            font-size: 12px;
            text-transform: uppercase;
        }
        .status-badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: 500;
        }
        .status-running { background: #238636; color: white; }
        .status-idle { background: #9e6a03; color: white; }
        .status-terminated { background: #f85149; color: white; }
        .provider-badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 500;
        }
        .provider-runpod { background: #6e40c9; color: white; }
        .provider-aws { background: #ff9900; color: black; }
        .event-log {
            background: #0d1117;
            border: 1px solid #30363d;
            border-radius: 6px;
            padding: 10px;
            max-height: 400px;
            overflow-y: auto;
            font-family: 'Monaco', 'Menlo', monospace;
            font-size: 12px;
        }
        .event-row {
            padding: 4px 8px;
            border-bottom: 1px solid #21262d;
        }
        .event-row:hover { background: #161b22; }
        .event-time { color: #8b949e; }
        .event-action-created { color: #3fb950; }
        .event-action-terminated { color: #f85149; }
        .event-action-checked { color: #58a6ff; }
        .timestamp {
            color: #8b949e;
            font-size: 12px;
            margin-top: 20px;
            text-align: center;
        }
        .no-data {
            color: #8b949e;
            text-align: center;
            padding: 40px;
        }
        .cost-warning {
            background: #f8514922;
            border: 1px solid #f85149;
            border-radius: 6px;
            padding: 12px;
            margin-bottom: 20px;
            color: #f85149;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ GPU Cost Guardian Dashboard</h1>
HTMLHEADER

# Add summary cards
RUNPOD_COUNT=$(echo "$RUNPOD_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([p for p in d if p.get('desiredStatus')=='RUNNING']))" 2>/dev/null || echo "0")
AWS_COUNT=$(echo "$AWS_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
TOTAL_RUNNING=$((RUNPOD_COUNT + AWS_COUNT))

# Calculate hourly cost
HOURLY_COST=$(echo "$RUNPOD_DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = sum(p.get('costPerHr', 0) for p in data if p.get('desiredStatus') == 'RUNNING')
print(f'{total:.2f}')
" 2>/dev/null || echo "0.00")

cat >> "$OUTPUT_FILE" << HTMLSUMMARY
        <div class="summary-cards">
            <div class="card">
                <div class="card-title">GPUs Running</div>
                <div class="card-value running">${TOTAL_RUNNING}</div>
            </div>
            <div class="card">
                <div class="card-title">RunPod Pods</div>
                <div class="card-value">${RUNPOD_COUNT}</div>
            </div>
            <div class="card">
                <div class="card-title">AWS Instances</div>
                <div class="card-value">${AWS_COUNT}</div>
            </div>
            <div class="card">
                <div class="card-title">Current Cost/Hour</div>
                <div class="card-value cost">\$${HOURLY_COST}</div>
            </div>
        </div>
HTMLSUMMARY

# Add warning if resources are running
if [ "$TOTAL_RUNNING" -gt 0 ]; then
    cat >> "$OUTPUT_FILE" << 'HTMLWARN'
        <div class="cost-warning">
            ⚠️ <strong>GPU resources are currently running!</strong> Make sure these are intentional.
            Run <code>./scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill</code> to terminate idle resources.
        </div>
HTMLWARN
fi

# Add RunPod table
cat >> "$OUTPUT_FILE" << 'HTMLRUNPOD'
        <h2>RunPod Pods</h2>
HTMLRUNPOD

if [ "$RUNPOD_COUNT" -gt 0 ]; then
    cat >> "$OUTPUT_FILE" << 'HTMLTABLE1'
        <table class="resource-table">
            <tr>
                <th>Pod ID</th>
                <th>Name</th>
                <th>GPU</th>
                <th>Status</th>
                <th>Cost/Hr</th>
                <th>Created</th>
            </tr>
HTMLTABLE1

    echo "$RUNPOD_DATA" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
for pod in data:
    if pod.get('desiredStatus') != 'RUNNING':
        continue
    pod_id = pod.get('id', 'unknown')
    name = pod.get('name', 'unnamed')
    gpu = pod.get('machine', {}).get('gpuDisplayName', 'unknown')
    cost = pod.get('costPerHr', 0)
    created = pod.get('createdAt', '')[:19]

    print(f'''<tr>
        <td><code>{pod_id}</code></td>
        <td>{name}</td>
        <td>{gpu}</td>
        <td><span class=\"status-badge status-running\">RUNNING</span></td>
        <td>\${cost:.2f}</td>
        <td>{created}</td>
    </tr>''')
" >> "$OUTPUT_FILE"

    echo "        </table>" >> "$OUTPUT_FILE"
else
    echo '        <div class="no-data">No RunPod pods running ✓</div>' >> "$OUTPUT_FILE"
fi

# Add AWS table
cat >> "$OUTPUT_FILE" << 'HTMLAWS'
        <h2>AWS GPU Instances</h2>
HTMLAWS

if [ "$AWS_COUNT" -gt 0 ]; then
    cat >> "$OUTPUT_FILE" << 'HTMLTABLE2'
        <table class="resource-table">
            <tr>
                <th>Instance ID</th>
                <th>Name</th>
                <th>Type</th>
                <th>Status</th>
                <th>Launched</th>
            </tr>
HTMLTABLE2

    echo "$AWS_DATA" | python3 -c "
import sys, json

data = json.load(sys.stdin)
for inst in data:
    inst_id = inst.get('id', 'unknown')
    name = inst.get('name', 'unnamed') or 'unnamed'
    inst_type = inst.get('type', 'unknown')
    state = inst.get('state', 'unknown')
    launch = inst.get('launch', '')[:19]

    status_class = 'status-running' if state == 'running' else 'status-idle'
    print(f'''<tr>
        <td><code>{inst_id}</code></td>
        <td>{name}</td>
        <td>{inst_type}</td>
        <td><span class=\"status-badge {status_class}\">{state.upper()}</span></td>
        <td>{launch}</td>
    </tr>''')
" >> "$OUTPUT_FILE"

    echo "        </table>" >> "$OUTPUT_FILE"
else
    echo '        <div class="no-data">No AWS GPU instances running ✓</div>' >> "$OUTPUT_FILE"
fi

# Add event log
cat >> "$OUTPUT_FILE" << 'HTMLEVENTS'
        <h2>Recent Events (24h)</h2>
        <div class="event-log">
HTMLEVENTS

if [ -f "$EVENT_LOG" ]; then
    # Get last 50 events, newest first
    tail -100 "$EVENT_LOG" 2>/dev/null | python3 -c "
import sys
import json

events = []
for line in sys.stdin:
    try:
        events.append(json.loads(line.strip()))
    except:
        pass

# Sort by timestamp descending
events.sort(key=lambda x: x.get('timestamp', ''), reverse=True)

for event in events[:50]:
    ts = event.get('timestamp', '')[:19].replace('T', ' ')
    provider = event.get('provider', 'unknown')
    action = event.get('action', 'unknown')
    resource = event.get('resource_id', 'unknown')
    details = event.get('details', {})

    provider_class = f'provider-{provider}'
    action_class = f'event-action-{action}'

    detail_str = ''
    if isinstance(details, dict):
        if 'reason' in details:
            detail_str = f\" - {details['reason']}\"
        elif 'status' in details:
            detail_str = f\" - {details['status']}\"

    print(f'''<div class=\"event-row\">
        <span class=\"event-time\">{ts}</span>
        <span class=\"provider-badge {provider_class}\">{provider.upper()}</span>
        <span class=\"{action_class}\">{action}</span>
        <code>{resource[:12]}</code>{detail_str}
    </div>''')
" >> "$OUTPUT_FILE"
else
    echo '<div class="no-data">No events logged yet</div>' >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << HTMLFOOTER
        </div>

        <p class="timestamp">Last updated: ${TIMESTAMP}</p>
        <p class="timestamp">
            <a href="https://github.com/davidbmar/whisperlive-runpod" style="color: #58a6ff;">
                GitHub: whisperlive-runpod
            </a>
        </p>
    </div>
</body>
</html>
HTMLFOOTER

echo "Dashboard generated: $OUTPUT_FILE"

#===============================================================================
# Upload to S3 (if configured)
#===============================================================================

if [ -n "$S3_BUCKET" ]; then
    echo "Uploading to S3: $S3_BUCKET"
    aws s3 cp "$OUTPUT_FILE" "${S3_BUCKET}index.html" \
        --content-type "text/html" \
        --cache-control "max-age=60" \
        2>/dev/null

    if [ $? -eq 0 ]; then
        # Extract bucket name and region for URL
        BUCKET_NAME=$(echo "$S3_BUCKET" | sed 's|s3://||' | cut -d'/' -f1)
        echo "Dashboard URL: http://${BUCKET_NAME}.s3.amazonaws.com/index.html"
    else
        echo "Warning: S3 upload failed"
    fi
else
    echo "S3 bucket not configured. Set GPU_DASHBOARD_S3_BUCKET in .env to enable upload."
    echo "View locally: file://$OUTPUT_FILE"
fi
