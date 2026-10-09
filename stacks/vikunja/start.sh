#!/bin/sh
# Registration is off, so the account comes from here: run the migrations,
# create VIKUNJA_ADMIN_USER if no user has VIKUNJA_ADMIN_EMAIL yet (a
# renamed account or a changed password is left alone), then start.
set -eu
cd /app/vikunja
./vikunja migrate
# (Exit status, not output: "not found" is logged with the email in it.)
if ! ./vikunja user list -e "$VIKUNJA_ADMIN_EMAIL" >/dev/null 2>&1; then
  ./vikunja user create -u "$VIKUNJA_ADMIN_USER" -e "$VIKUNJA_ADMIN_EMAIL" \
    -p "$VIKUNJA_ADMIN_PASSWORD"
fi
exec ./vikunja web
