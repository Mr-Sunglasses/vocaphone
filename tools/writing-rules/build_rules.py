#!/usr/bin/env python3
"""Writes assets/keyboard/writing-rules.json, the data behind Writing check.

    python3 tools/writing-rules/build_rules.py           # write
    python3 tools/writing-rules/build_rules.py --check   # fail if the file is stale

Both apps read the JSON: the kinds of suggestion and their messages, the word
tables, the rules (see WritingRule.kt for the pattern language) and the tone
lexicon. Edit the tables here, never the JSON.
"""

import json, sys
from pathlib import Path

KINDS = {
  # correctness
  "spelling":        ("correctness", "Spelling", True, "“{original}” looks misspelled. Did you mean “{replacement}”?"),
  "apostrophe":      ("correctness", "Missing apostrophe", True, "“{replacement}” needs an apostrophe."),
  "capitalization":  ("correctness", "Capitalization", True, "Use “{replacement}” here."),
  "punctuation":     ("correctness", "Punctuation", True, "Use “{replacement}” instead of “{original}”."),
  "repeated_word":   ("correctness", "Repeated word", True, "You typed “{original}” twice."),
  "confused_words":  ("correctness", "Commonly confused words", False, "“{original}” and “{replacement}” are easy to mix up. “{replacement}” fits here."),
  "agreement":       ("correctness", "Subject–verb agreement", False, "Make the verb agree with its subject: use “{replacement}”."),
  "verb_form":       ("correctness", "Verb form", False, "Use “{replacement}” here; “{original}” is the wrong form of the verb."),
  "article":         ("correctness", "Article", False, "“{replacement}” fits here better than “{original}”."),
  "missing_word":    ("correctness", "Missing word", False, "It looks like “{replacement}” is missing here."),
  "extra_word":      ("correctness", "Unnecessary word", False, "“{original}” isn't needed here."),
  "pronoun":         ("correctness", "Pronoun", False, "Use “{replacement}” here."),
  "preposition":     ("correctness", "Preposition", False, "“{replacement}” is the usual preposition here."),
  "noun_number":     ("correctness", "Singular or plural", False, "Use “{replacement}” to match the rest of the sentence."),
  "double_negative": ("correctness", "Double negative", False, "Two negatives cancel each other out. Use “{replacement}”."),
  "comparison":      ("correctness", "Comparison", False, "“{result}” already compares, so “{1}” isn't needed."),
  "word_choice":     ("correctness", "Word choice", False, "“{replacement}” may be the word you meant."),
  # clarity
  "wordiness":       ("clarity", "Wordy phrase", False, "“{result}” says the same thing in fewer words."),
  "redundancy":      ("clarity", "Redundant phrase", False, "“{match}” repeats itself; “{result}” is enough."),
  "passive_voice":   ("clarity", "Passive voice", False, "This is in the passive voice. Saying who does what can make it clearer."),
  "long_sentence":   ("clarity", "Long sentence", False, "This sentence has {count} words. Splitting it can make it easier to read."),
  # engagement
  "intensifier":     ("engagement", "Weak intensifier", False, "“{result}” is stronger than “{match}”."),
  "overused_word":   ("engagement", "Repetitive word", False, "You've used “{word}” {count} times here. A different word could keep it fresh."),
  # delivery
  "hedging":         ("delivery", "Hedging", False, "“{result}” sounds more confident."),
}

# Kind-specific messages the classifier chooses between. Placeholders:
# {original} {replacement} {previous} {next} {subject}.
MESSAGES = {
  "article.a_to_an": "Use “an” before a word that starts with a vowel sound, like “{next}”.",
  "article.an_to_a": "Use “a” before a word that starts with a consonant sound, like “{next}”.",
  "article.missing": "It looks like “{replacement}” is missing before “{next}”.",
  "article.extra": "“{original}” isn't needed before “{next}”.",
  "agreement.subject": "“{replacement}” agrees with “{subject}”.",
  "capitalization.i": "Always capitalize “I”.",
  "capitalization.start": "Start a sentence with a capital letter.",
  "punctuation.add_comma": "Add a comma here.",
  "punctuation.add_question": "This reads like a question, so end it with a question mark.",
  "punctuation.add_period": "End the sentence with a full stop.",
  "punctuation.add_other": "Add “{replacement}” here.",
  "punctuation.remove": "Remove the extra “{original}”.",
  "pronoun.subject": "Use the subject form “{replacement}” here.",
  "pronoun.object": "Use the object form “{replacement}” here.",
  "wordiness.remove": "You can drop “{original}” without changing the meaning.",
  "redundancy.remove": "“{original}” is already implied, so you can drop it.",
  "verb_form.do": "After “{1}”, use the base form “{replacement}”.",
  "verb_form.modal_not": "After “{1} not”, use “{replacement}”.",
  "hedging.remove": "Dropping “{original}” sounds more confident.",
  "missing_word.verb": "A verb seems to be missing: add “{replacement}”.",
  "extra_word.remove": "“{original}” isn't needed here.",
  "verb_form.after": "After “{previous}”, use “{replacement}”.",
  "confused_words.gloss": "“{replacement}” {replacement_gloss}; “{original}” {original_gloss}.",
}

GLOSSES = {
  "their": "means belonging to them", "there": "refers to a place or starts a sentence like “there is”",
  "they're": "means “they are”", "its": "means belonging to it", "it's": "means “it is” or “it has”",
  "your": "means belonging to you", "you're": "means “you are”", "whose": "means belonging to whom",
  "who's": "means “who is” or “who has”", "then": "is about time or order", "than": "compares two things",
  "to": "is a preposition or starts a verb, as in “to go”", "too": "means “also” or “more than enough”",
  "two": "is the number 2", "lose": "means to misplace or fail to win", "loose": "means not tight",
  "affect": "is usually the verb", "effect": "is usually the noun", "accept": "means to receive or agree",
  "except": "means “apart from”", "of": "is a preposition", "have": "is the verb in “could have”, “should have” and “would have”",
  "were": "is the past of “are”", "we're": "means “we are”", "where": "asks about or names a place",
  "here": "means in this place", "hear": "means to listen", "know": "means to be aware of", "no": "is the opposite of yes",
  "new": "means not old", "knew": "is the past of “know”", "right": "means correct or the opposite of left",
  "write": "means to put words down", "whole": "means entire", "hole": "is an opening or a gap",
  "weather": "is rain, sun and wind", "whether": "introduces a choice, like “if”", "passed": "is the past of “pass”",
  "past": "means earlier or beyond", "by": "means near or through", "buy": "means to purchase", "bye": "is goodbye",
  "fewer": "is for things you can count", "less": "is for amounts you can't count",
  "lie": "means to recline or to say something untrue", "lay": "means to put something down",
  "lying": "means reclining or saying something untrue", "laying": "means putting something down",
  "a": "goes before a consonant sound", "an": "goes before a vowel sound", "the": "points to something specific",
  "me": "is the object form", "i": "is the subject form", "him": "is the object form", "he": "is the subject form",
  "her": "is the object form", "she": "is the subject form", "them": "is the object form", "they": "is the subject form",
  "us": "is the object form", "we": "is the subject form", "who": "is the subject form", "whom": "is the object form",
  "principal": "means main or the head of a school", "principle": "is a rule or belief",
  "stationary": "means not moving", "stationery": "is writing paper", "compliment": "is praise",
  "complement": "completes or goes well with something", "advice": "is the noun", "advise": "is the verb",
  "breath": "is the noun", "breathe": "is the verb", "choose": "is the present", "chose": "is the past",
  "quiet": "means silent", "quite": "means fairly or completely", "desert": "is a dry place or means to abandon",
  "dessert": "is the sweet course", "piece": "is a part", "peace": "is calm or the absence of war",
  "brake": "slows a car", "break": "means to split or a pause", "threw": "is the past of “throw”",
  "through": "means from one side to the other", "thorough": "means careful and complete",
  "allowed": "means permitted", "aloud": "means out loud", "wear": "is for clothes", "ware": "is goods",
  "ensure": "means make certain", "insure": "means take out insurance",
}

CONFUSION_SETS = [
  ["their","there","they're"],["its","it's"],["your","you're"],["whose","who's"],["then","than"],
  ["to","too","two"],["lose","loose"],["affect","effect"],["accept","except"],["of","have"],
  ["were","we're","where"],["here","hear"],["know","no"],["new","knew"],["right","write"],["whole","hole"],
  ["weather","whether"],["passed","past"],["by","buy","bye"],["fewer","less"],["lie","lay"],["lying","laying"],
  ["principal","principle"],["stationary","stationery"],["compliment","complement"],["advice","advise"],
  ["breath","breathe"],["choose","chose"],["quiet","quite"],["desert","dessert"],["piece","peace"],
  ["brake","break"],["threw","through","thorough"],["allowed","aloud"],["ensure","insure"],
]

PRONOUNS = {
  "subject": ["i","you","he","she","it","we","they","who"],
  "object": ["me","you","him","her","it","us","them","whom"],
}

# base, past, participle (third person and -ing derived unless given)
IRREGULAR = [
 ("be","was","been","is","being"),("have","had","had","has",None),("do","did","done","does",None),
 ("go","went","gone","goes",None),("say","said","said",None,None),("make","made","made",None,None),
 ("get","got","gotten",None,"getting"),("know","knew","known",None,None),("think","thought","thought",None,None),
 ("take","took","taken",None,None),("see","saw","seen",None,"seeing"),("come","came","come",None,None),
 ("give","gave","given",None,None),("find","found","found",None,None),("tell","told","told",None,None),
 ("become","became","become",None,None),("leave","left","left",None,None),("feel","felt","felt",None,None),
 ("bring","brought","brought",None,None),("begin","began","begun",None,"beginning"),("keep","kept","kept",None,None),
 ("hold","held","held",None,None),("write","wrote","written",None,None),("stand","stood","stood",None,None),
 ("hear","heard","heard",None,None),("let","let","let",None,"letting"),("mean","meant","meant",None,None),
 ("set","set","set",None,"setting"),("meet","met","met",None,None),("run","ran","run",None,"running"),
 ("pay","paid","paid",None,None),("sit","sat","sat",None,"sitting"),("speak","spoke","spoken",None,None),
 ("lie","lay","lain","lies","lying"),("lead","led","led",None,None),("read","read","read",None,None),
 ("grow","grew","grown",None,None),("lose","lost","lost",None,None),("fall","fell","fallen",None,None),
 ("send","sent","sent",None,None),("build","built","built",None,None),("understand","understood","understood",None,None),
 ("draw","drew","drawn",None,None),("break","broke","broken",None,None),("spend","spent","spent",None,None),
 ("cut","cut","cut",None,"cutting"),("rise","rose","risen",None,None),("drive","drove","driven",None,None),
 ("buy","bought","bought",None,None),("wear","wore","worn",None,None),("choose","chose","chosen",None,None),
 ("seek","sought","sought",None,None),("throw","threw","thrown",None,None),("catch","caught","caught","catches",None),
 ("deal","dealt","dealt",None,None),("win","won","won",None,"winning"),("forget","forgot","forgotten",None,"forgetting"),
 ("lay","laid","laid",None,None),("sell","sold","sold",None,None),("fight","fought","fought",None,None),
 ("eat","ate","eaten",None,None),("teach","taught","taught","teaches",None),("sing","sang","sung",None,None),
 ("swim","swam","swum",None,"swimming"),("drink","drank","drunk",None,None),("fly","flew","flown","flies",None),
 ("hide","hid","hidden",None,None),("ride","rode","ridden",None,None),("shake","shook","shaken",None,None),
 ("steal","stole","stolen",None,None),("freeze","froze","frozen",None,None),("blow","blew","blown",None,None),
 ("ring","rang","rung",None,None),("sink","sank","sunk",None,None),("shrink","shrank","shrunk",None,None),
 ("show","showed","shown",None,None),("sleep","slept","slept",None,None),("put","put","put",None,"putting"),
 ("hit","hit","hit",None,"hitting"),("hurt","hurt","hurt",None,None),("cost","cost","cost",None,None),
 ("shut","shut","shut",None,"shutting"),("quit","quit","quit",None,"quitting"),("feed","fed","fed",None,None),
 ("bite","bit","bitten",None,None),("dig","dug","dug",None,"digging"),("hang","hung","hung",None,None),
 ("light","lit","lit",None,None),("shoot","shot","shot",None,None),("spin","spun","spun",None,"spinning"),
 ("stick","stuck","stuck",None,None),("strike","struck","struck",None,None),("swing","swung","swung",None,None),
 ("tear","tore","torn",None,None),("wake","woke","woken",None,None),("bend","bent","bent",None,None),
 ("lend","lent","lent",None,None),("bet","bet","bet",None,"betting"),("bear","bore","born",None,None),
 ("beat","beat","beaten",None,None),("bleed","bled","bled",None,None),("breed","bred","bred",None,None),
 ("flee","fled","fled",None,"fleeing"),("forgive","forgave","forgiven",None,None),("mistake","mistook","mistaken",None,None),
 ("overcome","overcame","overcome",None,None),("prove","proved","proven",None,None),("shine","shone","shone",None,None),
 ("slide","slid","slid",None,None),("split","split","split",None,"splitting"),("spread","spread","spread",None,None),
 ("sweep","swept","swept",None,None),("undo","undid","undone","undoes",None),("upset","upset","upset",None,"upsetting"),
 ("weep","wept","wept",None,None),("withdraw","withdrew","withdrawn",None,None),("arise","arose","arisen",None,None),
 ("awake","awoke","awoken",None,None),("forbid","forbade","forbidden",None,"forbidding"),("smell","smelled","smelled",None,None),
]

# Regular verbs whose forms the engine derives (+s, +ed, +ing). Irregular
# ones are listed above and are verbs too.
VERBS = """
accept add admire admit advise afford agree allow announce answer appear apply appreciate argue arrange arrive ask
attach attack attempt attend avoid bake balance ban belong blame boil book borrow bother bounce brush burn call
calm cancel care carry change charge chase chat check cheer chew clean clear click climb close coach collect comb
compare compete complain complete concern confess confirm connect consider contain continue cook copy correct cough
count cover crash crawl create cross cry dance decide declare delay deliver depend describe deserve destroy develop
die disagree disappear discover dislike divide doubt drag dream dress drop dry earn edit embarrass employ empty
encourage end enjoy enter escape excite excuse exist expect explain explore fail fetch fill finish fix float flow
fold follow force form gather glue grab greet guess guide hand handle happen hate head heat help hope hug hunt hurry
identify ignore imagine improve include increase inform inspect intend introduce invent invite iron join joke judge
jump kick kill kiss knock label land last laugh learn like listen live load lock look love manage mark marry match
matter measure melt mention mind miss mix move need notice obey offer open order own pack paint park pass pause
perform pick place plan plant play please point pour practice prefer prepare present pretend prevent print produce
promise protect provide pull pump punch push question race rain reach realize receive recognize record reduce refuse
regret relax release remain remember remind remove repair repeat replace reply report request rescue respect rest
return reveal rinse risk rob rub rush save scare scream search serve settle share shave shop shout sign skip smile
smoke snow solve sound spell spill spoil start stay step stop store study succeed suffer suggest supply support
suppose surprise surround suspect talk taste tease thank tick tie touch tour trade train transfer travel treat trust
try turn type unite unlock use vanish visit wait walk want warn wash waste watch wave welcome wish wonder work worry
wrap yell
""".split()

INTENSIFIED = [
  ("good","great"),("bad","terrible"),("big","huge"),("small","tiny"),("happy","delighted"),("sad","heartbroken"),
  ("tired","exhausted"),("important","crucial"),("hungry","starving"),("cold","freezing"),("hot","scorching"),
  ("scared","terrified"),("angry","furious"),("beautiful","gorgeous"),("quickly","rapidly"),("clean","spotless"),
  ("dirty","filthy"),("smart","brilliant"),("funny","hilarious"),("interesting","fascinating"),("boring","tedious"),
  ("loud","deafening"),("large","enormous"),("clear","obvious"),("sure","certain"),("excited","thrilled"),
  ("surprised","astonished"),("rich","wealthy"),("busy","swamped"),("easy","effortless"),("pretty","stunning"),
  ("ugly","hideous"),("worried","anxious"),("old","ancient"),("fast","rapid"),("simple","basic"),("careful","cautious"),
  ("wet","soaked"),("thin","slender"),("strong","powerful"),("weak","feeble"),("bright","dazzling"),("dark","pitch-black"),
]

WORDY = [
  ("in order to","to"),("in order for","for"),("due to the fact that","because"),("owing to the fact that","because"),
  ("in light of the fact that","because"),("on account of the fact that","because"),("despite the fact that","although"),
  ("in spite of the fact that","although"),("regardless of the fact that","although"),("at this point in time","now"),
  ("at the present time","now"),("at this moment in time","now"),("in this day and age","today"),("in the event that","if"),
  ("in the near future","soon"),("a large number of","many"),("a great number of","many"),("a small number of","a few"),
  ("the majority of","most"),("a majority of","most"),("with regard to","about"),("with regards to","about"),
  ("in regard to","about"),("with respect to","about"),("in reference to","about"),("in relation to","about"),
  ("prior to","before"),("subsequent to","after"),("in close proximity to","near"),("has the ability to","can"),
  ("have the ability to","can"),("is able to","can"),("are able to","can"),("make a decision","decide"),
  ("made a decision","decided"),("come to a conclusion","conclude"),("came to a conclusion","concluded"),
  ("give consideration to","consider"),("take into consideration","consider"),("make an attempt to","try to"),
  ("made an attempt to","tried to"),("for the purpose of","for"),("until such time as","until"),("on a daily basis","daily"),
  ("on a weekly basis","weekly"),("on a monthly basis","monthly"),("on a regular basis","regularly"),
  ("in a timely manner","promptly"),("at all times","always"),("the reason why is because","because"),
  ("the reason is because","because"),("as a matter of fact","in fact"),("it is important to note that",""),
  ("it should be noted that",""),("it goes without saying that",""),("needless to say",""),("all of a sudden","suddenly"),
  ("in the process of",""),("in an effort to","to"),("so as to","to"),("in the amount of","for"),("a sufficient number of","enough"),
  ("each and every","every"),("first and foremost","first"),("any and all","all"),("the fact that","that"),
]

REDUNDANT = [
  ("free gift","gift"),("end result","result"),("final outcome","outcome"),("past history","history"),("added bonus","bonus"),
  ("unexpected surprise","surprise"),("advance planning","planning"),("close proximity","proximity"),
  ("completely finished","finished"),("revert back","revert"),("repeat again","repeat"),("return back","return"),
  ("join together","join"),("combine together","combine"),("collaborate together","collaborate"),("very unique","unique"),
  ("absolutely essential","essential"),("actual fact","fact"),("brief summary","summary"),("future plans","plans"),
  ("general consensus","consensus"),("new innovation","innovation"),("true fact","fact"),("basic fundamentals","fundamentals"),
  ("ATM machine","ATM"),("PIN number","PIN"),("LCD display","LCD"),("first began","began"),("still remains","remains"),
  ("final conclusion","conclusion"),("personal opinion","opinion"),("mutual cooperation","cooperation"),
  ("exact same","same"),("sum total","total"),("plan ahead","plan"),("postpone until later","postpone"),
  ("refer back","refer"),("reply back","reply"),("circle around","circle"),("merge together","merge"),
]

HEDGES = [
  ("I just wanted to","I wanted to"),("I just want to","I want to"),("just checking in","checking in"),
  ("just wanted to check","wanted to check"),("I was wondering if you could","could you"),("I was just wondering","I was wondering"),
  ("I'm no expert, but",""),("I'm not an expert, but",""),("I could be wrong, but",""),("I may be wrong, but",""),
  ("if that makes sense",""),
]

SPELLING = [
  ("alot","a lot"),("definately","definitely"),("definatly","definitely"),("seperate","separate"),("recieve","receive"),
  ("recieved","received"),("occured","occurred"),("occurence","occurrence"),("untill","until"),("wich","which"),
  ("becuase","because"),("beacuse","because"),("tommorow","tomorrow"),("tommorrow","tomorrow"),("accomodate","accommodate"),
  ("goverment","government"),("enviroment","environment"),("beleive","believe"),("wierd","weird"),("truely","truly"),
  ("thier","their"),("freind","friend"),("freinds","friends"),("begining","beginning"),("neccessary","necessary"),
  ("necessery","necessary"),("occassion","occasion"),("publically","publicly"),("embarass","embarrass"),
  ("existance","existence"),("independant","independent"),("noticable","noticeable"),("persue","pursue"),
  ("posession","possession"),("reccomend","recommend"),("recomend","recommend"),("relevent","relevant"),
  ("succesful","successful"),("sucessful","successful"),("tounge","tongue"),("arguement","argument"),("calender","calendar"),
  ("concious","conscious"),("curiousity","curiosity"),("febuary","February"),("foriegn","foreign"),("gaurd","guard"),
  ("happend","happened"),("immediatly","immediately"),("knowlege","knowledge"),("liason","liaison"),("millenium","millennium"),
  ("mispell","misspell"),("peice","piece"),("realy","really"),("remeber","remember"),("rythm","rhythm"),("sieze","seize"),
  ("sincerly","sincerely"),("speach","speech"),("sucess","success"),("suprise","surprise"),("threshhold","threshold"),
  ("tomatos","tomatoes"),("unforseen","unforeseen"),("vaccum","vacuum"),("wellcome","welcome"),
  ("acheive","achieve"),("adress","address"),("agressive","aggressive"),("apparantly","apparently"),("basicly","basically"),
  ("buisness","business"),("comming","coming"),("commited","committed"),("completly","completely"),("dissapoint","disappoint"),
  ("dissapointed","disappointed"),("excercise","exercise"),("experiance","experience"),("finaly","finally"),
  ("grammer","grammar"),("guarentee","guarantee"),("harrass","harass"),("interupt","interrupt"),("judgement","judgment"),
  ("lisence","license"),("maintainance","maintenance"),("mischievious","mischievous"),("neice","niece"),("payed","paid"),
  ("pharoah","pharaoh"),("possibile","possible"),("prefered","preferred"),("privelege","privilege"),("propoganda","propaganda"),
  ("questionaire","questionnaire"),("recieving","receiving"),("refered","referred"),("resturant","restaurant"),
  ("sargent","sergeant"),("similiar","similar"),("supercede","supersede"),("tendancy","tendency"),
  ("truley","truly"),("twelth","twelfth"),("tyrany","tyranny"),("underate","underrate"),("usally","usually"),
  ("writting","writing"),("yeild","yield"),("irregardless","regardless"),("supposably","supposedly"),("expresso","espresso"),
  ("probly","probably"),("prolly","probably"),("defenitely","definitely"),("diffrent","different"),("differnt","different"),
  ("beautifull","beautiful"),("buisy","busy"),("tonite","tonight"),("thru","through"),
]

APOSTROPHES = [
  ("dont","don't"),("doesnt","doesn't"),("didnt","didn't"),("isnt","isn't"),("wasnt","wasn't"),("arent","aren't"),
  ("werent","weren't"),("havent","haven't"),("hasnt","hasn't"),("hadnt","hadn't"),("couldnt","couldn't"),
  ("wouldnt","wouldn't"),("shouldnt","shouldn't"),("mustnt","mustn't"),("im","I'm"),("ive","I've"),("thats","that's"),
  ("whats","what's"),("theyre","they're"),("youre","you're"),("youve","you've"),("youll","you'll"),("theyve","they've"),
  ("weve","we've"),("itll","it'll"),("thatll","that'll"),("wouldve","would've"),("couldve","could've"),
  ("shouldve","should've"),("doesn't","doesn't"),
]

COMPARATIVES = """better worse more less rather other bigger smaller larger greater higher lower faster slower older
younger taller shorter longer harder easier cheaper stronger weaker richer poorer happier sadder wiser smarter nicer
colder hotter warmer cooler further farther heavier lighter darker brighter louder quieter safer busier""".split()

SUPERLATIVE_ADJ = """easiest biggest smallest largest greatest highest lowest fastest slowest oldest youngest tallest
shortest longest hardest cheapest strongest weakest richest poorest happiest saddest best worst nicest coldest hottest
warmest coolest heaviest lightest darkest brightest loudest quietest safest busiest smartest""".split()

PLURAL_COUNT = """friends people cars books things items days hours minutes times problems mistakes errors options
choices calories words cups students children men women kids employees members users customers questions issues
bugs tasks emails messages photos pictures apples bottles chairs games""".split()

CLASSES = {
  "modal": "can could will would shall should may might must".split(),
  "subject": PRONOUNS["subject"],
  "object_pronoun": ["me","him","her","us","them"],
  "comparative": COMPARATIVES,
  "superlative": SUPERLATIVE_ADJ,
  "plural_count": PLURAL_COUNT,
  "neg_aux": "don't doesn't didn't can't cannot won't wouldn't couldn't shouldn't isn't aren't wasn't weren't haven't hasn't hadn't never".split(),
  "neg_do_modal": "don't doesn't didn't can't cannot won't wouldn't couldn't shouldn't mustn't".split(),
  "person": "i you he she we they".split(),
  "wh": "what where when why how who which".split(),
  "person_contraction": "i'm you're we're they're he's she's".split(),
  "its_possessed": "tail name owner own head eyes legs paws fur wings roof door screen battery size shape value price purpose place".split(),
  "possessed": "car house phone bag book idea turn job dog cat jacket keys coat seat fault money pen laptop umbrella room desk shoes".split(),
  "allowed_double": "that had bye no so ha haha now well very really yeah yes go".split(),
  "neg_object": ["nothing","nobody","nowhere","none","no"],
  "neg_verb": "have has had do did see saw know knew want need get got say said hear heard find found tell told give gave".split(),
  "do_q": ["do","does","did"],
  "be": "am is are was were be been being".split(),
  "be_have_get": "am is are was were be been being get got getting gets".split(),
  "gerund_verb": "enjoy enjoys enjoyed enjoying avoid avoids avoided avoiding finish finishes finished finishing consider considers considered considering mind minds minded suggest suggests suggested suggesting recommend recommends recommended recommending imagine imagines imagined imagining deny denies denied denying".split(),
  "your_followers": "welcome going coming not so too really always never gonna kidding joking".split(),
  "its_followers": "a an the been not going getting so too really just all about over ok okay fine raining".split(),
  "place_preposition": "over in out from up down around back".split(),
  "their_verbs": "is are was were will has have would".split(),
}

# Agreement rules check the pronoun is the subject. "I", "he", "she", "we" and
# "they" are subjects wherever they stand, unless they end a joined subject
# ("You and I are", "He and she are"). "You" and "it" are objects too ("What I
# told you was true", "the people behind it are"), so those rules fire only
# where a clause starts: the sentence start, a conjunction, a verb such as
# "think" that takes a clause, or a comma.
JOINED = ["and", "or", "nor"]
CLAUSE_START = """and but or so because cause if when whenever while since although though that think thought
know knew guess hope bet said say says believe feel felt mean sure , ; :""".split()
WH = CLASSES["wh"] + ["whose", "whom"]

def r(match, replace, kind, message=None, rid=None):
    d = {"match": match, "replace": replace, "kind": kind}
    if message: d["message"] = message
    if rid: d["id"] = rid
    return d

RULES = []
# Correctness: confusables in context the tagger leaves alone.
RULES += [
  r("{comparative} then", "$1 than", "confused_words", rid="then-than"),
  r("rather {verb_base} then", "$1 $2 than", "confused_words", rid="rather-then"),
  r("it's {its_possessed}", "its $2", "confused_words", rid="its-possessed"),
  r("could|should|would|must|might of", "$1 have", "confused_words", rid="could-of"),
  r("could|should|would|must|might of {verb_inflected}", "$1 have $3", "confused_words", rid="could-of-done"),
  r("^ your welcome", "you're $2", "confused_words", rid="your-welcome"),
  r("your {your_followers}", "you're $2", "confused_words", rid="your-youre"),
  r("its {its_followers}", "it's $2", "confused_words", rid="its-it-s"),
  r("it's own", "its own", "confused_words", rid="its-own"),
  r("^ their {their_verbs}", "there $2", "confused_words", rid="their-is"),
  r("their going|coming|doing|not|gonna", "they're $2", "confused_words", rid="their-going"),
  r("{place_preposition} their $", "$1 there", "confused_words", rid="over-their"),
  r("{place_preposition} they're $", "$1 there", "confused_words", rid="over-theyre"),
  r("who's {possessed}", "whose $2", "confused_words", rid="whos-car"),
  r("^ whose coming|going|there|here|that|this|in|next", "who's $2", "confused_words", rid="whose-coming"),
  r("^ were going|coming|leaving|here|done|ready|late|almost|not", "we're $2", "confused_words", rid="were-going"),
  # Not in a question: in "How can understanding help?" the word after the modal is its subject.
  dict(r("{modal} {verb_inflected}", "$1 ${base:2}", "verb_form", "verb_form.after", rid="modal-base"), notAtStart=True, notAfter=WH),
  dict(r("{modal} not {verb_inflected}", "$1 $2 ${base:3}", "verb_form", "verb_form.modal_not", rid="modal-not-base"), notAtStart=True, notAfter=WH),
  r("{neg_do_modal} {verb_inflected}", "$1 ${base:2}", "verb_form", "verb_form.after", rid="neg-base"),
  r("do|does|did not {verb_inflected}", "$1 $2 ${base:3}", "verb_form", "verb_form.modal_not", rid="do-not-base"),
  r("^ {do_q} {subject} {verb_inflected}", "$1 $2 ${base:3}", "verb_form", "verb_form.do", rid="do-question-base"),
  r("have|has|had {simple_past}", "$1 ${participle:2}", "verb_form", "verb_form.after", rid="have-participle"),
  r("{neg_aux} {neg_verb} {neg_object}", "$1 $2 ${any:3}", "double_negative", rid="double-negative"),
  # Subject-verb agreement the rules can be sure of without the model.
  r("{wh} is you|we|they", "$1 are $3", "agreement", "Use “are” with “{3}”.", rid="wh-is-you"),
  r("{wh} was you|we|they", "$1 were $3", "agreement", "Use “were” with “{3}”.", rid="wh-was-you"),
  dict(r("we|they is", "$1 are", "agreement", "Use “are” with “{1}”.", rid="they-is"), notAfter=JOINED),
  dict(r("you is", "$1 are", "agreement", "Use “are” with “{1}”.", rid="you-is"), after=CLAUSE_START),
  dict(r("we|they was", "$1 were", "agreement", "Use “were” with “{1}”.", rid="they-was"), notAfter=JOINED),
  dict(r("you was", "$1 were", "agreement", "Use “were” with “{1}”.", rid="you-was"), after=CLAUSE_START),
  dict(r("i is|are", "$1 am", "agreement", "Use “am” with “I”.", rid="i-is"), notAfter=JOINED),
  dict(r("he|she are", "$1 is", "agreement", "Use “is” with “{1}”.", rid="he-are"), notAfter=JOINED),
  dict(r("it are", "$1 is", "agreement", "Use “is” with “{1}”.", rid="it-are"), after=CLAUSE_START),
  dict(r("he|she don't", "$1 doesn't", "agreement", "Use “doesn't” with “{1}”.", rid="he-dont"), notAfter=JOINED),
  dict(r("it don't", "$1 doesn't", "agreement", "Use “doesn't” with “{1}”.", rid="it-dont"), after=CLAUSE_START),
  dict(r("i|we|they doesn't", "$1 don't", "agreement", "Use “don't” with “{1}”.", rid="they-doesnt"), notAfter=JOINED),
  dict(r("you doesn't", "$1 don't", "agreement", "Use “don't” with “{1}”.", rid="you-doesnt"), after=CLAUSE_START),
  r("most {superlative}", "$2", "comparison", rid="most-superlative"),
  r("more better|worse|bigger|smaller|easier|harder|faster|cheaper", "$2", "comparison", rid="more-comparative"),
  r("less {plural_count}", "fewer $2", "word_choice", "“Fewer” is for things you can count, like “{2}”.", rid="less-fewer"),
  r("{gerund_verb} to {verb_base}", "$1 ${ing:3}", "verb_form", "After “{1}”, use the -ing form: “{replacement}”.", rid="gerund-after"),
  r("look|looking|looked forward to {verb_base}", "$1 $2 $3 ${ing:4}", "verb_form", "After “look forward to”, use the -ing form: “{replacement}”.", rid="look-forward"),
  r("thanks for {verb_base} {object_pronoun}", "$1 $2 ${ing:3} $4", "verb_form", "After “for”, use the -ing form: “{replacement}”.", rid="thanks-for-ing"),
  r("thank you for {verb_base} {object_pronoun}", "$1 $2 $3 ${ing:4} $5", "verb_form", "After “for”, use the -ing form: “{replacement}”.", rid="thank-you-for-ing"),
  r("{person_contraction} used to {verb_base}", "$1 $2 $3 ${ing:4}", "verb_form", "“Used to” meaning “accustomed to” takes the -ing form: “{replacement}”.", rid="used-to-ing"),
  r("{person} am|are|is|was|were|get|got used to {verb_base}", "$1 $2 $3 $4 ${ing:5}", "verb_form", "“Used to” meaning “accustomed to” takes the -ing form: “{replacement}”.", rid="be-used-to-ing"),
  r("between you and I", "$1 $2 $3 me", "pronoun", "pronoun.object", rid="between-you-and-me"),
  r("^ me and {object_pronoun}", "${subject:3} and I", "pronoun", "Use the subject forms when they start the sentence: “{replacement}”.", rid="me-and-him"),
  r("^ {object_pronoun} and me", "${subject:1} and I", "pronoun", "Use the subject forms when they start the sentence: “{replacement}”.", rid="him-and-me"),
  r("^ me and {name}", "$3 and I", "pronoun", "Use “I” when it is part of the subject, and put yourself last: “{replacement}”.", rid="me-and-name"),
  r("for all intensive purposes", "for all intents and purposes", "word_choice", rid="intensive-purposes"),
  r("one in the same", "one and the same", "word_choice", rid="one-in-the-same"),
  r("case and point", "case in point", "word_choice", rid="case-and-point"),
  r("nip it in the butt", "nip it in the bud", "word_choice", rid="nip-in-the-bud"),
  r("could care less", "couldn't care less", "word_choice", rid="could-care-less"),
  r("{word} {same}", "$1", "repeated_word", rid="repeated-word"),
]
RULES += [r(a, b, "spelling", rid="spell-"+a) for a, b in SPELLING]
RULES += [r(a, b, "apostrophe", rid="apos-"+a) for a, b in APOSTROPHES if a != b]
RULES += [r(w, w[0].upper() + w[1:], "capitalization", "capitalization.i", rid="cap-" + w.replace("'", "")) for w in ["i", "i'm", "i've", "i'll", "i'd"]]
# Clarity
RULES += [r(a, b, "wordiness", "wordiness.remove" if b == "" else None, rid="wordy-"+a.replace(" ","-")) for a, b in WORDY]
RULES += [r(a, b, "redundancy", rid="redundant-"+a.replace(" ","-").lower()) for a, b in REDUNDANT]
RULES += [r("{be} {participle} by", None, "passive_voice", rid="passive-by")]
# Engagement
for w, s in INTENSIFIED:
    RULES.append(r(f"very|really {w}", s, "intensifier", rid=f"intensifier-{w}"))
# Delivery
RULES += [r(a, b, "hedging", "hedging.remove" if b == "" else None, rid="hedge-"+a.replace(" ","-").replace(",","").replace("'","").lower()) for a, b in HEDGES]

TONES = [
  {"id":"friendly","label":"Friendly","emoji":"😊","words":"thanks thank glad happy hope hi hey hello cheers love great awesome lovely wonderful nice welcome enjoy fun".split(),"phrases":["have a great","see you","talk soon","hope you","take care"]},
  {"id":"appreciative","label":"Appreciative","emoji":"🙏","words":"thanks thank grateful appreciate appreciated appreciation thankful".split(),"phrases":["thank you","many thanks","much appreciated","means a lot"]},
  {"id":"confident","label":"Confident","emoji":"🤝","words":"will definitely certainly sure confident clearly absolutely guarantee committed".split(),"phrases":["i'm sure","i am sure","i'm confident","i know","we will","i will"]},
  {"id":"tentative","label":"Tentative","emoji":"🤔","words":"maybe perhaps possibly might guess probably somewhat unsure".split(),"phrases":["i think","i guess","sort of","kind of","not sure","i was wondering","just wanted","if that makes sense","i could be wrong"]},
  {"id":"formal","label":"Formal","emoji":"🎩","words":"regards sincerely furthermore therefore however kindly hereby pursuant accordingly dear respectfully".split(),"phrases":["please find","i would like to","thank you for your","best regards","kind regards","to whom it may concern"]},
  {"id":"informal","label":"Informal","emoji":"✌️","words":"hey yeah yep nope gonna wanna lol omg btw tbh cool kinda sorta yo dude ok okay haha".split(),"phrases":["what's up","no worries","sounds good"]},
  {"id":"excited","label":"Excited","emoji":"🎉","words":"excited amazing awesome thrilled wow yay incredible fantastic".split(),"phrases":["can't wait","so excited","so happy"]},
  {"id":"apologetic","label":"Apologetic","emoji":"😔","words":"sorry apologize apologies apologise regret unfortunately".split(),"phrases":["my bad","my fault","i'm sorry","i am sorry","sorry for"]},
  {"id":"urgent","label":"Urgent","emoji":"⏰","words":"urgent asap immediately now deadline quickly critical emergency".split(),"phrases":["as soon as possible","right away","by today","end of day","time sensitive"]},
  {"id":"concerned","label":"Concerned","emoji":"😟","words":"worried concerned concern afraid unsure anxious nervous risk issue problem".split(),"phrases":["i'm worried","not sure if","i'm afraid"]},
  {"id":"frustrated","label":"Frustrated","emoji":"😤","words":"frustrated annoyed annoying unacceptable ridiculous disappointed angry upset again still".split(),"phrases":["this is the","once again","still not","not happy","fed up"]},
  {"id":"curious","label":"Curious","emoji":"🧐","words":"wonder curious why how what".split(),"phrases":["i wonder","do you know","any idea","could you tell"]},
]

doc = {
  "about": "Generated by tools/writing-rules/build_rules.py; edit that, not this. The rules and tables behind Writing check (English): kinds and messages, word tables, rules and the tone lexicon. Read by android/.../writing/ and ios/VocaPhoneShared/Writing/, tested by assets/grammar/writing_fixtures.json.",
  "version": 1,
  "kinds": {k: {"category": c, "title": t, "mechanical": m, "message": msg} for k,(c,t,m,msg) in KINDS.items()},
  "messages": MESSAGES,
  "glosses": GLOSSES,
  "confusions": CONFUSION_SETS,
  "pronouns": PRONOUNS,
  "articles": ["a","an","the"],
  "prepositions": "about above across after against along around at before behind below beside between by down during for from in inside into near of off on onto out over past since through till to toward towards under until up upon with within without".split(),
  "determiners": "a an the this that these those my your his her its our their one two three four five six seven eight nine ten many few several some both each every all no any".split(),
  "stopwords": "a an the and or but if so of to in on at by for with from as is are was were be been am i you he she it we they me him her us them my your his its our their this that these those there here not no do does did have has had will would can could should just very really then than also too what which who when where why how all any some more most other into over out up down about after before".split(),
  "verbs": sorted(set(VERBS)),
  "irregularVerbs": [list(t) for t in IRREGULAR],
  "classes": CLASSES,
  "rules": RULES,
  "tone": {"minimumCharacters": 90, "minimumScore": 4, "tones": TONES},
  "readability": {"wordsPerMinuteReading": 238, "wordsPerMinuteSpeaking": 150, "longSentenceWords": 40, "overusedWordCount": 3, "overusedWindowWords": 120},
  "score": {"weights": {"correctness": 4.0, "clarity": 2.0, "engagement": 1.0, "delivery": 1.0}, "minimumWords": 50},
}

def dump(d):
    # One rule per line, the rest pretty: diffable by hand.
    head = dict(d); rules = head.pop("rules")
    lines = json.dumps(head, ensure_ascii=False, indent=1).rstrip("}").rstrip().rstrip("\n")
    body = ",\n".join("  " + json.dumps(x, ensure_ascii=False) for x in rules)
    return lines + ',\n "rules": [\n' + body + "\n ]\n}\n"

ids=[x["id"] for x in RULES]
dupes={i for i in ids if ids.count(i)>1}
assert not dupes, dupes
known=set(CLASSES)|{"verb_base","verb_inflected","simple_past","participle","name","word","same"}
import re as _re
for x in RULES:
    for c in _re.findall(r"\{(\w+)\}", x["match"]):
        assert c in known, (x["id"], c)
out = Path(__file__).resolve().parents[2] / "assets" / "keyboard" / "writing-rules.json"
text = dump(doc)
json.loads(text)
if "--check" in sys.argv:
    if not out.exists() or out.read_text() != text:
        sys.exit(f"{out} is stale; run tools/writing-rules/build_rules.py")
    print(f"{out.name} is current ({len(RULES)} rules)")
else:
    out.write_text(text)
    print(len(RULES), "rules", len(text), "bytes")
