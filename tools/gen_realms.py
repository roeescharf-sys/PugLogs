import re, sys, unicodedata
src = open(sys.argv[1], encoding="utf-8").read()
rows = re.findall(r'^\[(\d+)\]="([^"]+)"', src, re.M)
out = {}
def slug(name):
    s = name.lower().replace("'", "").replace("’", "")
    s = "".join(c if c.isalnum() else "-" for c in s)
    return "-".join(p for p in s.split("-") if p)
def key(name):
    # Lua's string.lower only lowercases ASCII, so leave other letters as-is.
    s = re.sub(r"[\s\-'’]", "", name)
    return "".join(c.lower() if c.isascii() else c for c in s)
for _id, data in rows:
    f = data.split(",")
    if len(f) < 4 or f[3] != "EU": continue
    name, locale = f[0], f[2]
    english = f[4] if len(f) > 4 and f[4] else name
    out[key(name)] = slug(english)
    if english != name: out[key(english)] = slug(english)
lines = ["-- EU realm names (spaces, hyphens and apostrophes removed, lowercased) -> Warcraft Logs realm slug.",
         "-- Generated from LibRealmInfo's realm list (Copyright Phanx, zlib license).",
         "local _, ns = ...", "", "ns.RealmSlugs = ns.RealmSlugs or {}", "ns.RealmSlugs.eu = {"]
for k in sorted(out):
    lines.append(f'\t["{k}"] = "{out[k]}",')
lines.append("}")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(len(out), "entries")
