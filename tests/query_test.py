import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from handoff.model import Handoff
from handoff.query import filter_handoffs
pending = Handoff("Check logs")
accepted = Handoff("Check backup")
accepted.accept()
items = [pending, accepted]
assert filter_handoffs(items, "pending") == [pending]
assert filter_handoffs(items, "accepted") == [accepted]
assert items == [pending, accepted]
assert filter_handoffs([], "pending") == []
try:
    filter_handoffs(items, "unknown")
except ValueError:
    pass
else:
    raise AssertionError("unknown status accepted")
print("PASS: pending filter, accepted filter, input unchanged, empty result, unknown rejection")
