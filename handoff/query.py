def filter_handoffs(items, status):
    if status not in {"pending", "accepted"}:
        raise ValueError("unknown handoff status")
    return [item for item in items if item.status == status]
