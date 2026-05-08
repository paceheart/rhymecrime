#!/usr/bin/env ruby
# coding: utf-8

#
# control parameters
# Display toggles for CLI / tests live here. HTML output format is set in frontend/frontend.rb (OUTPUT_FORMAT).
#

$output_format = 'cgi'
$display_word_frequencies = false
$display_word_similarities = false

require "set"

# Optional per-request debug pruning context (set by build_rhymecrime_page when ?debug=1).
# When unset, falls back to globals so CLI and specs can flip $debug_pruning without the frontend.
RHYMECRIME_REQUEST_DEBUG = :rhymecrime_request_debug

def debug_pruning?
  ctx = Thread.current[RHYMECRIME_REQUEST_DEBUG]
  ctx ? ctx[:pruning] : $debug_pruning
end

def debug_pruned_tuples
  ctx = Thread.current[RHYMECRIME_REQUEST_DEBUG]
  ctx ? ctx[:pruned] : $debug_pruned_tuples
end

$debug_pruning = false
$debug_pruned_tuples = nil

# When set to a String (e.g. by build_rhymecrime_page), HTML fragments append to
# Thread.current[:html_output_buffer] instead of stdout. MUST be thread-local: Sinatra on Puma
# serves requests on multiple threads, and a process-wide $global would let concurrent requests
# overwrite each other's output buffers mid-response (e.g. a fidget query's tuples leaking into
# a pirate query's HTML).

#
# Public interface: rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
# see bin/rhyme.rb for documentation
#

require "net/http"
require "uri"
require "json"
require "cgi"
require_relative "../store/data_source"
require_relative "../utils"
require_relative "../phoneme.rb"
require_relative "../morphology/inflect"
require_relative "../morphology/lexical"
require_relative "../pronunciation.rb"
require_relative "../timing"

#
# utilities (defined before related.rb so cgi_print exists for helpers there)
#

def cgi_print(string)
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s
  elsif $output_format == "cgi"
    print string
  end
end

def emit_text(string)
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s
  else
    print string
  end
end

def emit_line(string = "")
  buf = Thread.current[:html_output_buffer]
  if buf
    buf << string.to_s << "\n"
  else
    puts string
  end
end

require_relative "../related"
require_relative "../store/feedback_store"
require_relative "../store/dynamo_store" if Rhymecrime::DataSource.dynamodb?

require_relative "../lexicon"
require_relative "../filter"
require_relative "../rhyme"
require_relative "../tuples"
require_relative "display"

#
# Thematic relatedness
#

module Rhymecrime
  # Process-global memo for find_related_words (same role as the former memery
  # memoize). Mutex: Puma serves concurrent threads; Lambda is single-threaded
  # per invocation. Cleared from RelatedWords.reset_caches! so inner-store
  # invalidation cannot return stale outer results.
  module FindRelatedWordsMemo
    class << self
      def clear!
        mutex.synchronize { cache.clear }
      end

      def find_related_words(word, include_self, include_rhymeless = true, common_only = false, max_candidates = SIMILAR_MAX)
        key = [word, include_self, include_rhymeless, common_only, max_candidates]
        mutex.synchronize do
          return cache[key] if cache.key?(key)

          words = []
          unless forbidden?(word)
            words = RelatedWords.find_thematically_related_words(word, include_self, include_rhymeless, common_only, max_candidates)
            words = filter_out_dispreferred_words(words, word)
          end
          cache[key] = words
        end
      end

      private

      def cache
        @cache ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end

# common_only: when true, restrict candidates to non-rare? headwords (words_we_care_about(..., true)).
def find_related_words(word, include_self, include_rhymeless = true, max_candidates = SIMILAR_MAX, common_only: false)
  Rhymecrime::FindRelatedWordsMemo.find_related_words(word, include_self, include_rhymeless, common_only, max_candidates)
end

def find_related_rhymes(rhyme, rel)
  # rhyme supplies the phonological anchor (we collect everything that rhymes
  # with it); rel supplies the directional relatedness cue (each surviving
  # rhyme must be thematically related *to +rel+*, in the cue→related sense
  # the classifier learned post-symmetry-break). Pre-directional this filter
  # was thematically_related?(rhyme, w), which checked relatedness against
  # the rhyme anchor instead of rel — silently fine when the classifier was
  # symmetric and rhyme happened to share a relatedness cluster with rel,
  # but wrong by construction now that direction matters and the column header
  # explicitly promises "rhymes for word1 related to word2".
  result = find_rhyming_words(rhyme, false)
  result = filter_out_dispreferred_words(result, rhyme)
  result = result.select { |w| thematically_related?(rel, w) }
end

#
# Central dispatcher
#

def focal_word(word)
  return "\"<span class='focal_word'>#{word}</span>\""
end

def rhymecrime(word1, word2, goal, output_format='text', debug_mode=false)
  # When you enter a single word,
  #   RhymeCrime displays rhymes for that word (see find_rhyming_words), separating out the rare words (see rare?)
  #   and in a separate column, displays sets of rhyming words (see find_rhyming_tuples)
  # When you enter two words,
  #   RhymeCrime first displays rhymes for WORD1 that are thematically related to WORD2 (see related_rhymes),
  #   and in a separate column, displays pairs of rhyming words (RHYME1 / RHYME2) in which RHYME1 is related to WORD1 and RHYME2 is related to WORD2. (see find_rhyming_pairs)
  $output_format = output_format
  $debug_mode = debug_mode
  header_eol = ":<div class='results'>"
  
  result = nil
  dregs = [ ]
  result_type = :error # :words, :tuples, :bad_input, :vacuous, :error
  result_header = "Unexpected error."

  # special cases
  if(word1 == "" and word2 == "")
    return nil, :vacuous, ""
  end
  if(word1 == "" and word2 != "")
    word1, word2 = word2, word1
  end

  # main list of cases
  case goal
  when "rhymes"
    result_header = "Rhymes for " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(find_preferred_rhyming_words(word1))
    result_type = :words
  when "related"
    result_header = "Words related to " + focal_word(word1) + header_eol
    result, dregs = filter_out_rare_words(filter_out_rhymeless_words(find_related_words(word1, false)))
    result_type = :words
  when "set_related"
    tuples = find_rhyming_tuples(word1)
    if tuples.nil?
      # find_rhyming_tuples returns nil only when the computed-store
      # path is authoritative (Lambda) and the cue has no set_related#<lemma>
      # row. Three reasons the cue might land here, each with its own copy:
      #
      #   * forbidden?(word1) — not in the published lexicon (scrubbed
      #     forbidden / never built / OOV). Curt "I don't like that word."
      #     for blocked cues; typos also land here.
      #   * unrhymable_stop_word?(word1) || semantically_promiscuous?(word1)
      #     — the word is a function word ("the", "of") or a generic
      #     emotional/discourse term ("nice", "good") that we explicitly
      #     decline to compute relateds for. The set_related goal is the
      #     one place we want the *union* of those two lists: unrhymable
      #     stop words are deleted from word_dict at build (so they
      #     never get a compute row); semantically-promiscuous words
    #     are also caught upfront by compute_column_for_goal in
    #     frontend/frontend.rb, but we keep the predicate here as the
      #     authoritative answer when callers reach rhymecrime via paths
      #     that bypass the upfront filter (CLI tools, eval scripts). The
    #     message matches promiscuous_message in frontend/frontend.rb so the
      #     two upstream paths render identically.
      #   * otherwise — the cue is rare / outside the computed cue
      #     universe. Apologetic response; the "I'll make a note" trailer
      #     is literal — FeedbackStore.record_uncomputed_cue! writes a
      #     row tagged with UNCOMPUTED_RELATED_TOKEN so the next
      #     compute round can surface and add the most-asked-about
      #     uncomputed cues. Soft-fails on backend trouble (see the
      #     rescue in FeedbackStore.record!) so a flaky feedback writer
      #     never 500s the user-visible response.
      result_header =
        if forbidden?(word1)
          "I don't like that word."
        elsif unrhymable_stop_word?(word1) || semantically_promiscuous?(word1)
          "\"#{word1}\" is semantically promiscuous; can't compute related words"
        else
          Rhymecrime::FeedbackStore.record_uncomputed_cue!(cue: word1)
          "Oops, I don't know what words are related to #{focal_word(word1)}, sorry! I'll make a note."
        end
      result, dregs = [], []
      result_type = :bad_input
    else
      result_header = "Rhyming word sets related to " + focal_word(word1) + header_eol
      result, dregs = filter_out_rare_tuples(tuples)
      result_type = :tuples
    end
  when "pair_related"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find rhyming pairs. For example, Word 1 = <span class='focal_word'>crime</span>, Word 2 = <span class='focal_word'>heaven</span>"
      result_type = :bad_input
    else
      result_header = "Rhyming word pairs where the first word is related to" + " " + focal_word(word1) + " and the second word is related to " + " " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_tuples(find_rhyming_pairs(word1, word2))
      result_type = :tuples
    end
  when "related_rhymes"
    if(word1 == "" or word2 == "")
      result_header = "I need two words to find related rhyming pairs. For example, Word 1 = <span class='focal_word'>please</span>, Word 2 = <span class='focal_word'>cats</span>"
      result_type = :bad_input
    else
      result_header = "Rhymes for" + " " + focal_word(word1) + " that are related to " + focal_word(word2) + header_eol
      result, dregs = filter_out_rare_words(find_related_rhymes(word1, word2))
      result_type = :words
    end
  else
    result_header = "Invalid selection."
    result_type = :bad_input
  end
  debug "result = #{result}"
  debug "result_type = #{result_type}"
  return result, dregs, result_type, result_header
end

#
# Utilities
#

def related?(word1, word2, include_self=false)
  # Is word1 thematically related to word2?
  word1 = preferred_form(word1)
  word2 = preferred_form(word2)
  !forbidden?(word1) && !forbidden?(word2) && thematically_related?(word1, word2)
end
