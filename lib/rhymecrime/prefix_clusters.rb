# frozen_string_literal: true

#
# Single morphological prefixes used by prefix_words (query.rb) for the rhyme filter
# and by syllabify_with_common_prefix_split (phonology.rb) for the syllabifier's prefix
# split. Order: longer before shorter where one contains another (inter before in).
# Overlaps HYPHEN_COMPOUND_LEADING_PARTICLES only on in, out, up — those serve
# different rules; do not merge arrays without checking both call sites.
#
# Intentionally restricted to *single* prefixes. Compound shapes like insub- in
# insubordinate are handled by recursive stripping in recursive_prefix_ancestors
# (query.rb), which iterates this list at each step. Don't add compound entries here as
# a band-aid — that's the smell that motivated the recursive refactor.
#

COMMON_PREFIXES = [
  'a',       # privative (atonal, asexual, achromatic, abiotic) and locative (aflame, ashore,
             # around, aground, abuzz). Accepts splash damage on words that merely start with
             # a (ajar/jar, acorn/corn, amid/mid, ahead/head, abut/but, avoid/void, ado/do,
             # abasement/basement...) -- those cases live in the unless they're not
             # derivationally related spec subcontext which is currently skipped.
  'aero',    # Greek combining form (aerodynamic, aeronautical).
  'along',   # alongside
  'alpha',   # alphanumeric.
  'an',
  'ante',
  'anti',
  'arch',
  'atto',    # SI prefix 10^-18.
  'auto',
  'be',      # beside, below, become (splash damage on between/tween etc.)
  'bi',
  'bio',     # Greek combining form (biology, biomedical, biotech). Splash damage: nothing
             # observed — opaque bio- words (biopsy/psy, biceps/ceps) don't share rimes
             # with their over-stripped tails.
  'centi',   # SI prefix 10^-2 (centimeter, centiliter, centigram).
  'chemo',   # Greek combining form (chemotherapy, chemotherapies).
  'co',
  'com',
  'con',
  'contra',
  'counter', # counterattack/attack, counterattacked/attacked, counterpoint/point,
             # counterespionage/espionage. The bare-stem pairs are also caught by
             # compound_modifier_remainders (both counter and attack are dict
             # headwords), but the inflected counterattacked → attacked peel
             # needs the explicit prefix entry because attacked isn't a dict
             # headword. Splash damage: counterfeit/feit, counterpane/pane,
             # countervail/vail — but feit/pane/vail aren't dict headwords
             # (or aren't in the rime cohort) so the filter never fires on them.
  'de',
  'deca',    # SI prefix 10^1 (US spelling).
  'deci',    # SI prefix 10^-1.
  'deka',    # SI prefix 10^1 (alt spelling).
  'demo',    # Greek combining form (demographic, demographics).
  'dis',
  'disen',   # compound dis- + en- (disenchanted → chanted). Now redundant with the
             # recursive stripping in recursive_prefix_ancestors (which also reaches
             # chanted via dis- → enchanted → en- → chanted); kept as a single-step
             # fast path and to document the historic compound entry.
  'down',    # downwind, downhill, downstream
  'dys',     # Greek negative: dysfunction, dysfunctional, dystopia, dyslexia, dysphoria.
             # Splash damage: nothing observed — opaque words starting with dys are
             # virtually all derivational (dys doesn't appear as a non-morphological
             # word-initial trigraph in English).
  'east',
  'echo',    # combining form (echolocation, echolocations). Opaque echo- words have
             # tails (echinacea→inacea, echinoderm→inoderm) that aren't dict, so the
             # filter never fires on them.
  'en',
  'endo',    # endothermic → thermic
  'euro',    # combining form (euromissiles, eurozone). europe→pe is non-dict so safe.
  'ex',
  'exa',     # SI prefix 10^18. Opaque exa- words (exact, example, exam, exalt, exasperate)
             # have non-dict tails, so the filter never fires on them.
  'exo',     # exothermic → thermic
  'extra',
  'femto',   # SI prefix 10^-15.
  'giga',    # SI prefix 10^9.
  'hecto',   # SI prefix 10^2.
  'hetero',
  'hippo',   # Greek combining form (hippocampus, hippopotamus).
  'homeo',
  'homo',
  'hyper',
  'hypo',    # Greek combining form (hypocritical, hypotension, hypothetical).
  'il',      # illegal, illicit, illogical
  'im',      # impure, impolite (splash damage on peach/impeach etc.)
  'in',
  'inter',
  'intra',
  'kilo',    # SI prefix 10^3 (kilometer, kilogram, kilowatt). The historical
             # rationale for excluding kilo- was that kilometer/thermometer should
             # rhyme — handled now by PREFIX_FILTER_SIBLING_ANCHOR_TAILS in query.rb,
             # which preserves the stress-shifted kilometer↔thermometer pairing
             # (and friends: speedometer, barometer, etc.) while still correctly
             # filtering kilometer↔meter and kilogram↔gram. centimeter and the
             # other front-stress SI compounds live in different rime cohorts and
             # don't interact with the carve-out at all.
  'lay',     # Compound modifier (layperson, layman, laymen). Treating it as a single-
             # prefix lets recursive_prefix_ancestors peel it in step with business, council,
             # etc., which are caught by the (length-gated) compound-modifier branch. Splash
             # damage: layout / out, layered / opaque tails — both rejected downstream by
             # the primary-stress-preservation gate in phoneme_tail_match? (the -out in
             # layout is AW2, not AW1) so the filter only fires when the resulting
             # compound element actually keeps primary stress (layperson's per).
  'loco',    # Greek combining form (locomotion, locomotive, locomotives). Unblocks
             # the currently-skipped ought_not_rhyme 'motion','locomotion' spec.
  'logo',    # combining form (logographic).
  'macro',
  'mega',    # SI prefix 10^6 (megabyte, megawatt, megameter).
  'meta',    # Greek combining form (metaphysical, metastatic, metacarpal). Opaque
             # meta- words (metaphor→phor, metabolism→bolism, metallic→llic) have
             # non-dict tails so the filter never fires on them.
  'micro',
  'mid',
  'milli',   # SI prefix 10^-3 (millimeter, milligram, milliliter).
  'mis',
  'mono',
  'multi',   # multimillionaire/millionaire, multinational/national, multipurpose/purpose,
             # multitask/task, multiform/form, multiplex/plex. Splash damage on words that
             # merely start with multi but aren't morphological derivations (none observed
             # so far — opaque uses like multiply/ply collapse correctly here too since
             # they ARE etymologically prefixed and we don't want them paired as rhymes).
  'nano',    # SI prefix 10^-9 (nanometer, nanosecond).
  'non',
  'north',
  'off',
  'omni',
  'out',
  'over',
  'para',    # Greek combining form (paralegal/legal, paramedic/medic, paranormal/normal,
             # paramilitary/military, parasympathetic/sympathetic). Splash damage:
             # paragraph/graph and paratext/text would be peeled — those ARE
             # etymological compounds, so the prefix filter firing on them is correct.
             # Opaque para- words (parade, paradox, parallel, parameter, paradise) have
             # non-dict tails so the filter never fires on them.
  'pen',     # Latin "almost" (penultimate, antepenultimate). Splash damage on words
             # that merely start with pen (penny, pencil, penal, pen, penance) — but
             # those don't share rimes with ultimate / ult, so the splash is bounded
             # by the rime cohort.
  'peta',    # SI prefix 10^15.
  'photo',   # Greek combining form (photochemical, photographic, photosynthesis,
             # photovoltaic).
  'physio',  # Greek combining form (physiological, physiotherapies).
  'pico',    # SI prefix 10^-12.
  'poly',    # Greek combining form (polytechnic, polyethylene, polyamorous).
  'porno',   # combining form (pornographic).
  'post',
  'pre',
  'proto',   # Greek combining form (prototypical). Iterated longer-first so it peels
             # ahead of pro- when both apply.
  'pseudo',  # pseudoscience/science etc.
  'pro',
  'psycho',  # Greek combining form (psychotherapy, psychoanalysis, psychological).
  'pyro',    # Greek combining form (pyrotechnic, pyromaniac).
  'radio',   # combining form (radioactive, radiological). Opaque radio- words
             # (radium→um, radius→us, radial→al) have non-dict tails so safe.
  're',
  'retro',   # Latin combining form (retroactive, retrovirus, retrogressive).
  'semi',    # semiautomatic/automatic, semistatic/static, semicircle/circle, etc.
             # semi is a rare dict headword (the rare? gate in
             # compound_modifier_remainders would otherwise reject the peel that
             # productive prefixes like multi — also listed here — would be caught
             # by). Same situation as thermo. Splash damage: virtually none —
             # semi- is almost exclusively a productive prefix in modern English
             # (no opaque semi words share rimes with their tails).
  'south',
  'steno',   # Greek combining form (stenographic).
  'stereo',  # Greek combining form (stereotypical, stereomicroscope).
  'sub',
  'super',
  'sym',
  'syn',
  'tele',
  'teleo',   # teleological → logical (tele → ological wouldn't match)
  'tera',    # SI prefix 10^12.
  'thermo',  # Greek combining form (thermoplastic/plastic, thermometer/meter,
             # thermonuclear/nuclear, thermodynamics/dynamics, thermosphere/sphere,
             # thermocouple/couple, thermotherapy/therapy). Listed here because
             # thermo is a rare dict headword (freq 2), so the rare? gate in
             # compound_modifier_remainders would otherwise reject the peel that
             # electro (freq 10) sails through. Splash damage on thermo words
             # whose tail is non-derivational is bounded by the pron-suffix-
             # alignment gate downstream.
  'trans',
  'tri',
  'typo',    # combining form (typographical).
  'un',
  'under',
  'uni',
  'up',
  'video',   # combining form (videoconferencing).
  'yocto',   # SI prefix 10^-24.
  'yotta',   # SI prefix 10^24.
  'zepto',   # SI prefix 10^-21.
  'zetta',   # SI prefix 10^21.
]

#
# consonant clusters and syllabification
#

ALL_INITIAL_CONSONANT_CLUSTERS = [
  'B L', # blue
  'B R', # bread
  'B W', # bueno
  'B Y', # bugle
  'F Y', # few
  'D R', # draw
  'D W', # dwell
  'D Y', # due(1)
  'F L', # flaw
  'F R', # free
  'G L', # glow
  'G R', # grow
  'G W', # guava
  'HH Y', # hue
  'K L', # claw
  'K R', # crow
  'K W', # quick
  'K Y', # cue
  'M Y', # mute
  'P L', # play
  'P R', # pray
  'P W', # pueblo
  'P Y', # pupil
  'S F', # sphere
  'S K', # sky
  'S K L', # sclera
  'S K R', # scrub
  'S K W', # squall
  'S K Y', # skew
  'S P Y', # spume
  'S L', # sled
  'S M', # small
  'S N', # snow
  'S P', # speech
  'S P L', # split
  'S P R', # spray
  'S T', # stay
  'S T R', # straw
  'S W', # sway
  'SH L', # schlock
  'SH M', # schmooze
  'SH R', # shred
  'SH T', # schtick
  'SH W', # schwa
  'T R', # tree
  'T W', # twig
  'TH R', # throw
  'TH W', # thwack
  'V Y', # view
  'JH W', # joie (ʒw — merged with JH cluster inventory)
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work

# Onset clusters legal only at the true start of a word (forward order). Not consulted for medial
# syllabification, so e.g. L AY1 V L IY0 (lively) keeps V in the preceding coda instead of merging V+L.
WORD_INITIAL_CONSONANT_CLUSTERS = [
  'V L', # Vlad, Vladimir; Slavic Vl- names
].freeze

ALL_FINAL_CONSONANT_CLUSTERS = [
  'B D', # grabbed
  'B Z', # cubs
  'CH T', # patched
  'D TH', # width
  'D TH S', # widths
  'D S T', # midst, rare
  'D Z', # adze
  'DH D', # clothed
  'DH Z', # clothes
  'F S', # graphs
  'F T', # soft
  'F T S', # lifts
  'F TH', # fifth
  'F TH S', # fifths
  'G D', # bogged
  'G Z', # eggs
  'JH D', # bulged
  'K S', # fix
  'K S T', # fixed
  'K S T S', # texts
  'K T', # act
  'K T S', # acts
  'L B', # bulb
  'L B Z', # bulbs
  'L CH', # belch
  'L CH T', # belched
  'L D', # build
  'L D Z', # builds
  'L F', # gulf
  'L F S', # gulfs
  'L F T', # engulfed
  'L F TH', # twelfth, rare
  'L F TH S', # twelfths, rare
  'L JH', # bulge
  'L JH D', # bulged
  'L K', # silk
  'L K S', # silks
  'L K T', # milked
  'L M', # film
  'L M D', # filmed
  'L M Z', # films
  'L N', # kiln, rare
  'L N Z', # kilns, rare
  'L P', # help
  'L P S', # helps
  'L P T', # helped
  'L P T S', # sculpts, rare
  'L S', # else
  'L S T', # pulsed
  'L T', # salt
  'L T S', # salts
  'L TH', # wealth
  'L TH S', # wealths
  # 'L TH T', # wealthed? theoretically possible, but doesn't occur
  'L V', # valve
  'L V D', # solved
  'L V Z', # valves
  'L Z', # feels
  'M D', # framed
  'M F', # triumph
  'M F S', # triumphs
  'M F T', # triumphed
  'M P', # jump
  'M P S', # jumps
  'M P S T', # glimpsed
  'M P T', # jumped
  'M P T S', # tempts
  'M T', # dreamt
  'M Z', # dooms
  'N CH', # punch
  'N CH T', # punched
  'N D', # send
  'N D Z', # sends
  'N JH', # change
  'N JH D', # changed
  'N S', # fence
  'N S T', # fenced
  'N T', # cent
  'N T S', # cents
  'N T S T', # incensed (?)
  'N TH', # tenth
  'N TH S', # tenths
  # 'N TH T', # tenthed? theoretically possible, but doesn't occur
  'N Z', # bronze
  'N Z D', # bronzed
  'NG D', # wronged
  'NG K', # ink
  'NG K S', # inks
  'NG K T', # inked
  'NG K T S', # instincts
  'NG K TH', # length
  'NG K TH S', # lengths
  # 'NG TH T', # lengthed? theoretically possible, but doesn't occur
  'NG Z', # things
  'P S', # lapse
  'P S T', # lapsed
  'P T', # apt
  'P T S', # opts
  'P TH', # depth
  'P TH S', # depths
  'R B', # curb
  'R B D', # curbed
  'R B Z', # curbs
  'R CH T', # arched
  'R CH', # arch
  'R D', # beard
  'R D Z', # beards
  'R DH Z', # berths
  'R F', # scarf
  'R F S', # scarfs
  'R F T', # scarfed
  'R G', # morgue
  # 'R G D', # morgued? theoretically possible, but doesn't occur
  'R G Z', # morgues
  'R JH', # merge
  'R JH D', # merged
  'R K', # mark
  'R K T', # marked
  'R K S', # marks
  'R L D', # world
  'R L D Z', # worlds
  'R L', # curl
  'R L Z', # curls
  'R M', # storm
  'R M D', # stormed
  'R M TH', # warmth
  # 'R M TH S', # warmths? theoretically possible, but doesn't occur
  'R M Z', # storms
  'R N', # earn
  'R N D', # earned
  'R N T', # burnt
  'R N Z', # burns
  'R P', # harp
  'R P S', # harps
  'R P T', # excerpt
  'R P T S', # excerpts
  'R S', # force
  'R S T', # forced
  'R S T S', # bursts
  'R SH', # marsh
  'R SH T', # borscht
  'R T', # part
  'R T S', # parts
  'R TH', # north
  'R TH S', # births
  'R TH T', # unearthed, rare
  'R V', # curve
  'R V D', # curved
  'R V Z', # curves
  'R Z', # furs
  'S K', # mask
  'S K S', # masks
  'S K T', # masked
  'S P', # clasp
  'S P S', # clasps
  'S P T', # clasped
  'S T', # chest
  'S T S', # chests
  'SH T', # mashed
  'T S', # eats
  'T S T', # blitzed
  'TH S', # breaths
  'TH T', # bequeathed
  'V D', # caved
  'V Z', # drives
  'Z D', # dozed
] # ARPABET format. source: John Algeo, https://www.tandfonline.com/doi/pdf/10.1080/00437956.1978.11435661 + original work (JH D covers camouflaged)

# Words with weird initial/final consonant clusters that should be included anyway
WHITELIST = [
  'dvorak',
  'neuroscience',
  'neuroscientist',
  'nyet',
  'sbarro',
  'schneider',
  'svelte',
  'tsetse',
  'tsunami',
  'vlad',
  'vladimir',
  'vroom',
  'voila',
  'zloty',
  'zlotys',
]
