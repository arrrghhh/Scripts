#!/bin/bash
# notify.sh — send failure alerts via HA (primary) or SMTP (fallback)
# Opt-in: if docker/<endpoint>/alert.env is missing or incomplete, this exits 0.

set -u

ENDPOINT="${1:?usage: notify.sh <endpoint> <subject> <body>}"
SUBJECT="${2:?usage: notify.sh <endpoint> <subject> <body>}"
BODY="${3:?usage: notify.sh <endpoint> <subject> <body>}"

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_ENV="$BASE/$ENDPOINT/alert.env"

[ -f "$ALERT_ENV" ] || exit 0

# shellcheck disable=SC1090
. "$ALERT_ENV"

HOSTNAME="$(hostname -s)"
FULL_SUBJECT="[$HOSTNAME/$ENDPOINT] $SUBJECT"
FULL_BODY="$BODY

Host: $(hostname -f 2>/dev/null || hostname)
Endpoint: $ENDPOINT
Time: $(date -u +%FT%TZ)
"

# Try HA first if configured
if [ -n "${HA_TOKEN_FILE:-}" ] && [ -f "$HA_TOKEN_FILE" ]; then
  HA_URL="${HA_URL:-http://127.0.0.1:8123}"
  HA_NOTIFY_TARGET="${HA_NOTIFY_TARGET:-persistent_notification}"
  TOKEN="$(cat "$HA_TOKEN_FILE")"
  
  if [ "$HA_NOTIFY_TARGET" = "persistent_notification" ]; then
    python3 - "$HA_URL" "$TOKEN" "$FULL_SUBJECT" "$FULL_BODY" << 'PY' 2>/dev/null && exit 0
import sys, json, urllib.request
url, token, title, msg = sys.argv[1:5]
data = json.dumps({"title": title, "message": msg}).encode()
req = urllib.request.Request(url + "/api/services/notify/persistent_notification", data=data, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(req, timeout=10).read()
PY
  else
    python3 - "$HA_URL" "$TOKEN" "$HA_NOTIFY_TARGET" "$FULL_SUBJECT" "$FULL_BODY" << 'PY' 2>/dev/null && exit 0
import sys, json, urllib.request
url, token, target, title, msg = sys.argv[1:6]
# target is like notify/mobile_app_pixel_11_pro
svc = target.replace("/", "/")
data = json.dumps({"title": title, "message": msg}).encode()
req = urllib.request.Request(url + "/api/services/" + svc, data=data, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(req, timeout=10).read()
PY
  fi
fi

# Fallback to email if HA didn't work
[ -n "${ALERT_TO:-}" ] || exit 0
[ -n "${SMTP_HOST:-}" ] || exit 0
[ -n "${SMTP_PORT:-}" ] || exit 0
[ -n "${SMTP_USER:-}" ] || exit 0
[ -n "${SMTP_PASS:-}" ] || exit 0
[ -n "${ALERT_FROM:-}" ] || ALERT_FROM="$SMTP_USER"

export PYTHONUNBUFFERED=1
python3 - "$SMTP_HOST" "$SMTP_PORT" "$SMTP_TLS" "$SMTP_USER" "$SMTP_PASS" "$ALERT_FROM" "$ALERT_TO" "$FULL_SUBJECT" "$FULL_BODY" <<'PY'
import sys, smtplib, ssl
from email.mime.text import MIMEText
from email.utils import formatdate

host, port, tls, user, pwd, sender, rcpt, subject, body = sys.argv[1:10]
port = int(port)
msg = MIMEText(body)
msg['From'] = sender
msg['To'] = rcpt
msg['Subject'] = subject
msg['Date'] = formatdate(localtime=True)
try:
    if tls == 'ssl':
        ctx = ssl.create_default_context()
        s = smtplib.SMTP_SSL(host, port, context=ctx, timeout=30)
    else:
        s = smtplib.SMTP(host, port, timeout=30)
        if tls in ('starttls','true','yes','1'):
            ctx = ssl.create_default_context()
            s.starttls(context=ctx)
    s.login(user, pwd)
    s.sendmail(sender, [rcpt], msg.as_string())
    s.quit()
    sys.exit(0)
except Exception as e:
    print("notify.sh: failed to send alert: %s" % e, file=sys.stderr)
    sys.exit(0)
PY
