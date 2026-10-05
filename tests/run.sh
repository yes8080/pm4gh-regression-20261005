#!/usr/bin/env bash
set -eu
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PYTEST'
from handoff.model import Handoff
h = Handoff("Check backup")
assert h.status == "pending"
h.accept()
assert h.status == "accepted"
try:
    Handoff("   ")
except ValueError:
    pass
else:
    raise AssertionError("empty title accepted")
try:
    h.accept()
except ValueError:
    pass
else:
    raise AssertionError("duplicate acceptance allowed")
print("PASS: initial state, acceptance, blank-title rejection, duplicate rejection")
PYTEST
if [ -f tests/query_test.py ]; then python3 tests/query_test.py; fi
