"""Format of the data the addon puts in its QR codes.

First line (header), tab-separated:
    PL2  batch  page  pages  region  encounterID  keyLevel  dungeonName  [flags  [filtered]]
    flags: "R" = the paste box was opened: copy the results (with players: look them up first)
Then one line per applicant member, tab-separated:
    applicationID  name  realmSlug  classID  role(T/H/D)  itemLevel  score  [specPosition 1-4]

A batch with no member lines means "no applicants" (or the listing ended).
"""
from dataclasses import dataclass, field

MAGIC = "PL2"
CLASS_FILES = {1: "WARRIOR", 2: "PALADIN", 3: "HUNTER", 4: "ROGUE", 5: "PRIEST", 6: "DEATHKNIGHT",
               7: "SHAMAN", 8: "MAGE", 9: "WARLOCK", 10: "MONK", 11: "DRUID", 12: "DEMONHUNTER",
               13: "EVOKER"}
ROLES = {"T": "TANK", "H": "HEALER", "D": "DAMAGER"}

# Spec names in Blizzard's order within each class (the addon sends the position).
SPECS = {
    "WARRIOR": ["Arms", "Fury", "Protection"],
    "PALADIN": ["Holy", "Protection", "Retribution"],
    "HUNTER": ["Beast Mastery", "Marksmanship", "Survival"],
    "ROGUE": ["Assassination", "Outlaw", "Subtlety"],
    "PRIEST": ["Discipline", "Holy", "Shadow"],
    "DEATHKNIGHT": ["Blood", "Frost", "Unholy"],
    "SHAMAN": ["Elemental", "Enhancement", "Restoration"],
    "MAGE": ["Arcane", "Fire", "Frost"],
    "WARLOCK": ["Affliction", "Demonology", "Destruction"],
    "MONK": ["Brewmaster", "Mistweaver", "Windwalker"],
    "DRUID": ["Balance", "Feral", "Guardian", "Restoration"],
    "DEMONHUNTER": ["Havoc", "Vengeance", "Devourer"],
    "EVOKER": ["Devastation", "Preservation", "Augmentation"],
}
CLASS_NAMES = {"WARRIOR": "Warrior", "PALADIN": "Paladin", "HUNTER": "Hunter", "ROGUE": "Rogue",
               "PRIEST": "Priest", "DEATHKNIGHT": "Death Knight", "SHAMAN": "Shaman", "MAGE": "Mage",
               "WARLOCK": "Warlock", "MONK": "Monk", "DRUID": "Druid", "DEMONHUNTER": "Demon Hunter",
               "EVOKER": "Evoker"}


def spec_name(class_file, index):
    specs = SPECS.get(class_file, [])
    return specs[index - 1] if 0 < index <= len(specs) else ""


@dataclass
class Member:
    application_id: int
    name: str
    realm_slug: str
    class_file: str
    spec: str
    role: str
    item_level: int
    score: int
    spec_index: int = 0       # position of their spec within the class (1-4), 0 = unknown

    @property
    def key(self):
        return f"{self.name}-{self.realm_slug}".lower()


@dataclass
class Page:
    batch: str
    page: int
    pages: int
    region: str
    encounter_id: int
    key_level: int
    dungeon: str
    members: list = field(default_factory=list)
    flags: str = ""
    filtered: int = 0          # applicants hidden by your filters in WoW (not sent)


def _int(text):
    try:
        return int(text)
    except ValueError:
        return 0


def parse(text):
    """Returns a Page, or None if the text isn't a PugLogs QR code."""
    lines = text.split("\n")
    head = lines[0].split("\t")
    if len(head) < 8 or head[0] != MAGIC:
        return None
    page = Page(batch=head[1], page=_int(head[2]), pages=_int(head[3]), region=head[4],
                encounter_id=_int(head[5]), key_level=_int(head[6]), dungeon=head[7],
                flags=head[8] if len(head) > 8 else "",
                filtered=_int(head[9]) if len(head) > 9 else 0)
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) < 7:
            continue
        class_file = CLASS_FILES.get(_int(f[3]), "")
        spec_index = _int(f[7]) if len(f) > 7 else 0
        page.members.append(Member(_int(f[0]), f[1], f[2], class_file, spec_name(class_file, spec_index),
                                   ROLES.get(f[4], ""), _int(f[5]), _int(f[6]), spec_index))
    return page
