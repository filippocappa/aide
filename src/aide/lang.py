"""Which language a few words are in: Italian or English, the two the user speaks."""

import re

_IT = set("il lo la le gli di del della delle dei che è non per una sono hai ho alle allo alla con mi ti ci si sì "
          "domani oggi grazie ciao cosa quando dove anche ma poi questo questa quello fatto fare va bene vuoi "
          "puoi devo c'è perché adesso dopo prima ancora ok".split())
_EN = set("the and is are you to of it that for on with have has what when where tomorrow today yes please "
          "thanks thank at can will your my this was there done want would could should then now let i'll i'm "
          "you're it's".split())


def language(text: str, default: str = "en") -> str:
    """"it" or "en", from the short words that give each away; `default` when it can't tell."""
    words = re.findall(r"[a-zà-ú']+", text.lower())
    it, en = sum(w in _IT for w in words), sum(w in _EN for w in words)
    return "it" if it > en else "en" if en > it else default
