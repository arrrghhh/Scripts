#!/bin/bash
# notify.sh — send failure alerts via HA (primary) or SMTP (fallback)
# Opt-in: if docker/<endpoint>/alert.env is missing or incomplete, this exits 0.
#
# A failed send is never silent: it is reported on stderr (which lands in the
# caller's run log) and the script exits 1 so the breakage is visible.

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

HA_URL="${HA_URL:-http://127.0.0.1:8123}"
HA_NOTIFY_TARGET="${HA_NOTIFY_TARGET:-persistent_notification}"
ha_attempted=0

# Try HA first if configured
if [ -n "${HA_TOKEN_FILE:-}" ]; then
  ha_attempted=1
  if [ ! -f "$HA_TOKEN_FILE" ]; then
    echo "notify.sh: HA_TOKEN_FILE is set but missing: $HA_TOKEN_FILE (skipping HA)" >&2
  else
    TOKEN="$(cat "$HA_TOKEN_FILE")"
    ha_err="$(mktemp)"
    if [ "$HA_NOTIFY_TARGET" = "persistent_notification" ]; then
      python3 - "$HA_URL" "$TOKEN" "$FULL_SUBJECT" "$FULL_BODY" << 'PY' 2>"$ha_err"
import sys, json, urllib.request
url, token, title, msg = sys.argv[1:5]
data = json.dumps({"title": title, "message": msg}).encode()
req = urllib.request.Request(url + "/api/services/notify/persistent_notification", data=data, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(req, timeout=10).read()
PY
      ha_rc=$?
    else
      python3 - "$HA_URL" "$TOKEN" "$HA_NOTIFY_TARGET" "$FULL_SUBJECT" "$FULL_BODY" << 'PY' 2>"$ha_err"
import sys, json, urllib.request
url, token, target, title, msg = sys.argv[1:6]
data = json.dumps({"title": title, "message": msg}).encode()
req = urllib.request.Request(url + "/api/services/" + target, data=data, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(req, timeout=10).read()
PY
      ha_rc=$?
    fi
    if [ "$ha_rc" -eq 0 ]; then
      rm -f "$ha_err"
      exit 0
    fi
    echo "notify.sh: HA notify via '$HA_NOTIFY_TARGET' failed: $(tail -n 1 "$ha_err")" >&2
    rm -f "$ha_err"
  fi
fi

# Fallback to email if HA didn't work
email_attempted=0
if [ -n "${ALERT_TO:-}" ] && [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_PORT:-}" ] \
   && [ -n "${SMTP_USER:-}" ] && [ -n "${SMTP_PASS:-}" ]; then
  email_attempted=1
  [ -n "${ALERT_FROM:-}" ] || ALERT_FROM="$SMTP_USER"

  export PYTHONUNBUFFERED=1
  if python3 - "$SMTP_HOST" "$SMTP_PORT" "${SMTP_TLS:-}" "$SMTP_USER" "$SMTP_PASS" "$ALERT_FROM" "$ALERT_TO" "$FULL_SUBJECT" "$FULL_BODY" <<'PY'
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
except Exception as e:
    print("notify.sh: failed to send alert email: %s" % e, file=sys.stderr)
    sys.exit(1)
PY
  then
    exit 0
  fi
  echo "notify.sh: email alert to $ALERT_TO failed" >&2
fi

if [ "$ha_attempted" -eq 0 ] && [ "$email_attempted" -eq 0 ]; then
  exit 0   # opt-in: no channel configured for this endpoint
fi

echo "notify.sh: ERROR: no alert channel succeeded for $ENDPOINT" >&2
exit 1
