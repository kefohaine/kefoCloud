#!/bin/sh
# WriteFreely first-boot: copy the app tree into the data volume, generate
# config.ini from the environment ONCE (it is operator-editable afterwards),
# then generate keys and initialise the SQLite schema. Idempotent: every step
# is skipped when its artefact already exists, so a recreate never rotates keys
# or touches the database.
set -eu

DATA=/data
APP=/opt/writefreely

if [ ! -x "$DATA/writefreely" ]; then
  cp -a "$APP/." "$DATA/"
fi
cd "$DATA"

if [ ! -f config.ini ]; then
  : "${WF_HOST:?WF_HOST is required (https://blog.example.com)}"
  cat > config.ini <<EOF
[server]
hidden_host =
port = 8080
bind = 0.0.0.0
tls_cert_path =
tls_key_path =
templates_parent_dir = $DATA
static_parent_dir = $DATA
pages_parent_dir = $DATA
keys_parent_dir = $DATA

[database]
type = sqlite3
filename = $DATA/writefreely.db

[app]
site_name = ${WF_SITE_NAME:-Blog}
site_description = ${WF_SITE_DESCRIPTION:-Writing}
host = $WF_HOST
theme = write
single_user = ${WF_SINGLE_USER:-false}
open_registration = ${WF_OPEN_REGISTRATION:-false}

[users]
default_visibility = public
EOF
fi

[ -s keys/email.aes256 ] || ./writefreely keys generate
[ -s writefreely.db ] || ./writefreely db init

exec ./writefreely
