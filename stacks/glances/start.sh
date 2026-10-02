#!/bin/sh
# Writes Glances' password file from GLANCES_PASSWORD (generated into .env by
# lab), then starts Glances with it: its API and web UI then need the user
# "glances" and that password. The file format matches what `glances
# --password` saves: salt$pbkdf2(pbkdf2(password)).
set -eu
py="/venv/bin/python${PYTHON_VERSION}"
mkdir -p /root/.config/glances
cd /app
"$py" -c 'import os
from glances.password import GlancesPassword as P
p = P()
open(p.password_file, "w").write(p.hash_password(p.get_hash(os.environ["GLANCES_PASSWORD"])))'
exec "$py" -m glances $GLANCES_OPT
