## goal

To help me write better limericks quicklier.

## to-do list

* improve good outputs
** relatedness isn't symmetric. For set_related, we don't have to go related1, related2, rhyme. We could also go related, rhyme, related to input. Blocked on semantic relatedness.
** look for all plurals that differ in vowels to find more phonemes to conflate, e.g. ORPHANAGE  [AO1 R F AH0 N AH0 JH] ORPHANAGES  [AO1 R F AH0 N IH0 JH IH0 Z]

* imperfect rhymes
** TH / DH
** sitter / admit her
** piton / lightin'
** mansion / stanchion
** snapshot -> trap's wrought
** bacon -> they can (bring back "CAN(1)  K AH0 N" but only when used as part of a phrase)

* eliminate dependence on datamuse
** wordnet?
** maybe NLTK wup_similarity or https://stackoverflow.com/questions/14148986/how-do-you-write-a-program-to-find-if-certain-words-are-similar/14638272#14638272

* reduce dumb outputs
** fix close / enclose, bass / base by pushing down only_preferred to find_rhyming_words so it can have access to the pronunciation
** filter out spelling variants from rime dict, e.g. UW_S_EH_F  yousef youssef yusef. But how to know whether it's a spelling variant or a homonym?
** hyphens
*** standardize "i r a" vs. "ira" and "san-jose" oughta be "san_jose" but "so-so" oughta stay "so-so"
** more scalable solution for British English, e.g. advisable / realisable

* urlencode word links
* test input phrases
* mine Limerick Heist for more test cases

## user requests

* show identical rhymes in "for the brazen" instead of eliminating them entirely

## could-do list

* make better use of vertical space, to reduce the need to scroll down
* add a clickable "x" for "this is a dumb word that should be stricken from the list forever"
** in the dregs, add a clickable up-arrow for "this is a good word that does not deserve to be down here"
* guess at pronunciations of unknown words
* make word_dict a text file too
* instead of eliminating identical rhymes entirely, just put them in the dregs along with the imperfect rhymes. There are a few it's sad to lose, like illicit / solicit, and vegetarian / totalitarian
* reduce dumb outputs via better rarity filtering
** WordNet contains saffron and paroled. Why do we need lemma_en? We count a word as common if it has a frequency of 2 or more (@todo try upping this) according to lemma_en, or if it exists in WordNet at all. If we upped this to 2, 2/3 of the newly-rare words would be crap, but we would also lose 1/3 good words like chicanery, noncombatants, propagandize, and psilocybin. That's probably okay.
** separate names out

## add these as test cases

query / wary
participate / anticipate (dregs)
informant / torment (imperfect)

magic

good:
chants / trance

bad:
disenchanted / enchanted

medical

disease / expertise / fees 

also "cc's"

## Do better with preferred forms
cataloging / catalogging
gramaphone / gramophone
old-fashioned / oldfashioned
in-laws / inlaws
pompom / pom-pom
shant / shan't
