#!/usr/bin/env ruby
#
# Determine semantic similarity of words based on their WordNet glosses
#

require 'rwordnet'
require_relative 'WetCorpus'
require_relative 'dict/utils_rhyme'

class WordNetReverseDictionary

  Hash @index # word mentioned in gloss -> the words it's mentioned in the gloss of

  def initialize
    @index = Hash.new_hash_of_arrays
    for word in words_we_care_about
      for form in WordNetReverseDictionary.all_word_forms(word)
        for gloss_word in WordNetReverseDictionary.gloss_words(form)
          for gloss_form in WordNetReverseDictionary.all_word_forms(gloss_word)
            @index.push(gloss_form, word) unless gloss_form == word
            @index.push(gloss_form, gloss_word) unless gloss_form == gloss_word
          end
        end
      end
    end
  end
  
  def self.glosses(word)
    word = preferred_form(word)
    synsets = WordNet::Synset.find_all(word)
    synsets.map { |s| s.gloss }
  end

  # All the words in all the glosses of WORD, except WORD itself and irrelevant words.
  def self.gloss_words(word)
    result = Set.new
    for gloss in glosses(word)
      for gloss_word in gloss.scan(/[\w'-]+|[[:punct:]]+/)
        gloss_word = gloss_word.downcase
        gloss_word = preferred_form(gloss_word)
        if gloss_word != word && word_we_care_about?(gloss_word)
          for form in WordNetReverseDictionary.all_word_forms(gloss_word)
            result.add(gloss_word)
          end
        end
      end
    end
    result
  end

  def self.all_word_forms(word)
    WordNet::Synset.morphy_all(word)
  end

  # Does the gloss for WORD mention GLOSS_WORD?
  def gloss_mentions?(word, gloss_word)
    word = preferred_form(word)
    gloss_word = preferred_form(gloss_word)
    @index[gloss_word].include?(word)
  end

  # Does the gloss for WORD1 mention WORD2, or vice versa?
  def gloss_cooccurs?(word1, word2)
    gloss_mentions?(word1, word2) || gloss_mentions?(word2, word1)
  end

end

#p WordNetReverseDictionary.glosses('asterisk')
