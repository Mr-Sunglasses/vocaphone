#!/usr/bin/env python3
"""Writes assets/keyboard/en-spelling.txt, Writing check's spelling dictionary.

    python3 tools/writing-rules/build_spelling.py            # download the lists, write
    python3 tools/writing-rules/build_spelling.py --check    # fail if the file is stale
    python3 tools/writing-rules/build_spelling.py --lists DIR   # use lists saved in DIR

The words come from the English Speller Database (SCOWL), size 60 (the size
most spell checkers ship as "en_US"), with US, British, Canadian and Australian
spellings all accepted: someone writing "colour" or "organise" is not wrong.
They are downloaded from the database's own list builder at app.aspell.net at
four sizes, so each word also says how common it is. Possessives ("dog's") are
left out because the checkers strip "'s" themselves.

The file has sections, each a heading line then one word per line:

    @35 @40 @50 @60   lower-case words, by the smallest SCOWL size they are in
    @proper           names and other words with a capital, accepted as written
                      (and in lower case from four letters on), never suggested
    @accept           chat and tech words outside SCOWL: accepted, never suggested

How a word ranks among the suggestions is its line in `en.txt`, the keyboard's
frequency list, when it is there, and its section otherwise. See
`WritingSpelling.kt` / `WritingSpelling.swift`.
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "keyboard" / "en-spelling.txt"
SIZES = [35, 40, 50, 60]
URL = ("http://app.aspell.net/create?max_size={size}&spelling=US&spelling=GBs&spelling=GBz&spelling=CA"
       "&spelling=AU&max_variant=1&diacritic=strip&special=hacker&special=roman-numerals"
       "&download=wordlist&encoding=utf-8&format=inline")

# Words people type that SCOWL size 60 does not have. Accepted, never suggested.
ACCEPT = """
lol lols lmao lmfao rofl omg omfg omw btw idk idc tbh imo imho brb ttyl thx tysm pls plz ty np nvm smh fyi aka irl
dm dms hmu wyd wbu hbu ikr jk gg af fomo yolo bae bff bffs lowkey highkey ngl fr rn tmrw tmr tho cuz coz bc yall
ya yah yeah yeh yep yup nope nah mhm hmm hmmm huh ugh uhh uh um umm oops whoa woah wow yay aww awww ok okay okey kk
haha hahaha hahahaha hehe hehehe heh xoxo xo bday gf bf ppl msg msgs pic pics vid vids info convo
covid vax vaxxed telehealth zoomed onboarding offboarding async sync
app apps wifi login logins logout signup signups username usernames email emails emailed emailing inbox
smartphone smartphones screenshot screenshots selfie selfies podcast podcasts hashtag hashtags emoji emojis
livestream livestreams livestreaming chatbot chatbots repo repos npm json api apis url urls backend frontend
devops kubernetes docker config configs dev devs admin admins ios macos android iphone iphones ipad ipads airpods
whatsapp instagram tiktok youtube spotify netflix uber airbnb gmail facebook linkedin reddit github gitlab
slack google googled googling venmo zelle paypal doordash ubereats grubhub lyft
tfw tl dr tldr fwiw afaik iirc imma gotta kinda sorta dunno lemme gimme wanna gonna y'all ya'll
standup standups retro retros signoff signoffs offsite offsites onsite onsites liveness kubectl repo
dev devops prod staging dashboard dashboards hotfix hotfixes changelog changelogs workflow workflows
toolchain toolchains codebase codebases webhook webhooks frontend backend fullstack serverless
microservice microservices timezone timezones rideshare carpool carpooling skincare haircut
""".split()

# All-capital SCOWL words of three letters that people type in lower case
# ("lol", "btw", "omg"), except those a slip on a common word lands on:
# "amd" is "and" with a neighbouring key.
LOWERED_ACRONYMS_EXCEPT = {"amd"}


def fetch(size: int, lists: Path | None) -> str:
    if lists is not None:
        return (lists / f"size{size}.txt").read_text(encoding="utf-8")
    with urllib.request.urlopen(URL.format(size=size), timeout=120) as r:
        return r.read().decode("utf-8")


def split(text: str) -> tuple[str, list[str]]:
    lines = text.split("\n")
    cut = max(i for i, l in enumerate(lines) if l.strip() == "---")
    return "\n".join(lines[:cut]), [l.strip() for l in lines[cut + 1:] if l.strip()]


def build(lists: Path | None) -> str:
    level: dict[str, int] = {}
    notice = ""
    for size in SIZES:
        notice, words = split(fetch(size, lists))
        for w in words:
            if w.endswith("'s"):
                continue
            level.setdefault(w, size)
    lower = {w: s for w, s in level.items() if w == w.lower()}
    proper = sorted(w for w in level if w != w.lower())
    acronyms = {w.lower() for w in proper if len(w) == 3 and w.isalpha() and w.isupper()}
    accept = sorted(({w for w in ACCEPT} | acronyms) - LOWERED_ACRONYMS_EXCEPT - set(lower))
    revision = next((l.strip() for l in notice.splitlines() if l.startswith("ESDB Git Revision")), "")
    head = [
        "Writing check's spelling dictionary. Generated by tools/writing-rules/build_spelling.py;",
        "edit that, not this. Words from the English Speller Database, size 60, US, British,",
        f"Canadian and Australian spellings ({revision}), built at https://app.aspell.net/create.",
        "",
    ]
    # The notice as the list builder ships it, minus its "Custom wordlist" preamble.
    body = notice[notice.index("Copyright"):].rstrip().splitlines()
    out = ["# " + l if l else "#" for l in head + body]
    for size in SIZES:
        out.append(f"@{size}")
        out += sorted(w for w, s in lower.items() if s == size)
    out.append("@proper")
    out += proper
    out.append("@accept")
    out += accept
    return "\n".join(out) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--lists", type=Path)
    args = ap.parse_args()
    text = build(args.lists)
    if args.check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            sys.exit(f"{OUT} is stale; run tools/writing-rules/build_spelling.py")
        print(f"{OUT.name} is current")
        return
    OUT.write_text(text, encoding="utf-8")
    print(f"{OUT.name}: {len(text.splitlines())} lines, {len(text.encode()) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
