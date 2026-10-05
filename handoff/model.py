from dataclasses import dataclass

@dataclass
class Handoff:
    title: str
    status: str = "pending"

    def __post_init__(self):
        if not self.title.strip():
            raise ValueError("title required")

    def accept(self):
        self.status = "accepted"
