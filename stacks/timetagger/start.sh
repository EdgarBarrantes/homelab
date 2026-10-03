#!/bin/sh
# Turns TIMETAGGER_PASSWORD (generated into .env by lab) into the bcrypt
# credentials TimeTagger expects, then starts it. One account:
# TIMETAGGER_USER with that password.
set -eu
TIMETAGGER_CREDENTIALS="$TIMETAGGER_USER:$(python -c 'import os, bcrypt
print(bcrypt.hashpw(os.environ["TIMETAGGER_PASSWORD"].encode(), bcrypt.gensalt()).decode())')"
export TIMETAGGER_CREDENTIALS
unset TIMETAGGER_PASSWORD
exec python -m timetagger
