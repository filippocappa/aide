"""Which language a few words are in: Italian or English, the two the user speaks."""

import re

# Everyday words of each, leaving out the ones both share ("in", "me", "no", "so", "come", "a", "i", "fine"): a
# short question must still give itself away ("How did I sleep last night?" had none of a shorter list, so a call
# answered it in Italian, with the Italian voice).
_IT = set("""
il lo la le gli un uno una di da con su per tra fra e ed o ma se che chi cui non più anche già ancora sempre mai
molto poco tutto tutti tutta questo questa questi quello quella quelli mio mia miei tuo tua tuoi suo sua nostro
sono sei è siamo siete ho hai ha abbiamo avete hanno era ero stato stata fatto fare faccio fai fa dire detto dimmi
posso puoi può vorrei vuoi voglio devo deve devi c'è ci mi ti si ne del della dello delle dei degli al alla allo
ai alle dal dalla dai nel nella nei nelle sul sulla sui l'ho l'hai va poi
ieri oggi domani dopodomani dopo prima adesso ora quando dove perché cosa quanto quanta quanti quante quale quali
grazie ciao sì bene allora però invece qualcosa niente nulla altro altra lascia stare perdere fallo annulla procedi
conferma certo esatto aspetta sposta metti aggiungi cancella ricordami leggimi dammi fammi trova cerca
sto stai sta mattina pomeriggio sera stasera notte stanotte giorno giorni settimana mese anno ore minuti
lunedì martedì mercoledì giovedì venerdì sabato domenica dormito mangiato speso prossimo prossima ultima ultimo
""".split())
_EN = set("""
the an and or but if is are was were be been am do does did don't doesn't didn't have has had how what when where
why who which whose there here this that these those it it's its i'm i've i'll i'd you your you're we our they
them their he she him her my mine to of for on at by from with about into up out over under not yes yeah please
thanks thank can could will would should shall may might must get got go going tell show give make take need want
like know think last next night morning afternoon evening week month day days today tomorrow yesterday tonight
much many any some all more most few just also only still again then now done okay hi hey hello let let's what's
anything nothing monday tuesday wednesday thursday friday saturday sunday slept sleep ate spent read remind move
add delete cancel
""".split())


def language(text: str, default: str = "en") -> str:
    """"it" or "en", from the everyday words that give each away; `default` when it can't tell."""
    words = re.findall(r"[a-zà-ú']+", text.lower())
    it, en = sum(w in _IT for w in words), sum(w in _EN for w in words)
    return "it" if it > en else "en" if en > it else default
