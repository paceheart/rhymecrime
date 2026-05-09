## goal

To help me write better limericks quicklier.

## to-do list

* improve good outputs
** look for all plurals that differ in vowels to find more phonemes to conflate, e.g. ORPHANAGE  [AO1 R F AH0 N AH0 JH] ORPHANAGES  [AO1 R F AH0 N IH0 JH IH0 Z]

* imperfect rhymes
** TH / DH
** mansion / stanchion
** bacon -> they can (bring back "CAN(1)  K AH0 N" but only when used as part of a phrase)

maybe NLTK wup_similarity or https://stackoverflow.com/questions/14148986/how-do-you-write-a-program-to-find-if-certain-words-are-similar/14638272#14638272

* reduce dumb outputs
** fix close / enclose, bass / base by pushing down only_preferred to find_rhyming_words so it can have access to the pronunciation
** filter out spelling variants from rime dict, e.g. UW_S_EH_F  yousef youssef yusef. But how to know whether it's a spelling variant or a homonym?
** hyphens
*** standardize "i r a" vs. "ira" and "san-jose" oughta be "san_jose" but "so-so" oughta stay "so-so"

* urlencode word links
* test input phrases

## user requests

* show rich rhymes in "for the brazen" instead of eliminating them entirely

## could-do list

* make better use of vertical space, to reduce the need to scroll down
* in the dregs, add a clickable up-arrow for "this is a good word that does not deserve to be down here"
* guess at pronunciations of unknown words

mosaic rhymes, e.g. commander / understand her

handle unicode in input, e.g. saute (with accent on e)

handle compound words like "ice cream" "cream cheese" "hot dog"

## Genderfluid rhymes

Genderfluid rhyme: each syllable from the primary-stressed syllable onward has an exactly matching rime (nucleus + coda), checked syllable-by-syllable. Subsumes masculine, feminine, and dactylic rhyme regardless of syllable count.

Non-binary rhyme: a genderfluid rhyme that is not a perfect rhyme. The individual syllable rimes all match, but the intervening onsets (consonant clusters between syllables) differ, so the overall contiguous rime does not match. Examples: latex / paychecks, pitiful / biddable.

fix this duplication:
accidental / dental / gentle / lentil / oriental / rental
accidental / gentle / kennel / oriental

converse / curse / immerse / perverse / purse / reverse / worse
conversed / cursed / immersed / pursed / reversed / thirst / worst
converses / curses / immerses / purses / reverses / versus
Each of them is almost entirely redundant with the other two, but each tuple has one word that's unique to it. Suggest one or more ways of displaying this to the user that follow best UX practices such as minimizing redundant information, grouping related things together, etc

our / scour
our / scour / tower

try again to strengthen lemma to semantic_base and see if it helps
we should be able to go even hammer with semantic_base, e.g. sembase(conflagration) -> fire

do something about ever / however / howsoever / whatever / whatsoever / whenever / wherever / whichever / whichsoever / whoever / whomever / whomsoever / whosoever

make it actually follow up on the "I'll make a note" notes

in single column, add a "jump to"

explain what it does

get rid of initialisms

try retraining relatedness with whatever mapped to related_ish, or related_ish_ish
try retraining relatedness with 5 classes: related, related_ish, whatever, unrelated_ish, unrelated

try Float16

cheese -> cassavas / guavas, why not cassava / guava?

try asking some LLMs for 100 or 1000 words related to 'pirate'. try various prompts.
try RoBERTa

make a test that ensures everything in awesome.csv works
