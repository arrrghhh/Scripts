#!/bin/bash
# notify.sh — send failure alerts via SMTP (comcast smarthost style or generic).
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

[ -n "${ALERT_TO:-}" ] || exit 0
[ -n "${SMTP_HOST:-}" ] || exit 0
[ -n "${SMTP_PORT:-}" ] || exit 0
[ -n "${SMTP_USER:-}" ] || exit 0
[ -n "${SMTP_PASS:-}" ] || exit 0
[ -n "${ALERT_FROM:-}" ] || ALERT_FROM="$SMTP_USER"

HOSTNAME="$(hostname -s)"
FULL_SUBJECT="[$HOSTNAME/$ENDPOINT] $SUBJECT"
FULL_BODY="$BODY

Host: $(hostname -f 2>/dev/null || hostname)
Endpoint: $ENDPOINT
Time: $(date -u +%FT%TZ)
"

export PYTHONUNBUFFERED=1
python3 - "$SMTP_HOST" "$SMTP_PORT" "$SMTP_TLS" "$SMTP_USER" "$SMTP_PASS" "$ALERT_FROM" "$ALERT_TO" "$FULL_SUBJECT" "$FULL_BODY" <<'PY'
import os, sys, smtplib, ssl
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
    sys.exit(0)  # never fail the unit because of alerting
PY
