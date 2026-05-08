# coding: utf-8

#
# Display
#

def print_synsets(synsets, input_word)
  # prints the synsets in SYNSETS that are nontrivial wrt INPUT_WORD
  isFirst = true
  for synset in synsets
    synonyms = synset.words - [ input_word ]
    unless(synonyms.empty?)
      unless isFirst
        cgi_print "<br>"
      end
      isFirst = false;
      cgi_print "<i>"
      emit_line(short_gloss(synset))
      cgi_print "</i>"
      emit_line
      print_words(synonyms)
    end
  end
end

def short_gloss(synset)
  gloss = synset.gloss
  i = gloss.index(';')
  if i
    return gloss[0,i]
  else
    return gloss
  end
end

# cues in tuple/words printers can be:
#   * nil — no thumbs feedback rendered (e.g. plain rhymes column).
#   * a String — uniform cue for every slot (set_related uses word1; the
#     debug related column uses word1; related_rhymes uses word2).
#   * an Array — per-slot cue, parallel to the tuple (used by pair_related,
#     where slot 0's cue is word1 and slot 1's cue is word2).
# cue_for resolves which to use for a given slot index in a tuple.
def cue_for(cues, index)
  return nil if cues.nil?
  cues.is_a?(Array) ? cues[index] : cues
end

def print_tuple(tuple, focal_word=false, cues: nil)
  # this basically just pushes the rare words to the end, but we could do something snazzier if we want
  pruned_class = (debug_pruning? && debug_pruned_tuples&.include?(tuple)) ? " output_tuple_pruned" : ""
  cgi_print "<div class='output_tuple#{pruned_class}'><p class='output_p'>"
  # Sub-tuples (good/bad) inherit a sliced view of cues when cues is an
  # Array, so the per-slot cue stays aligned with the rare-word reordering.
  good_idx = tuple.each_index.reject { |i| rare?(tuple[i]) }
  bad_idx  = tuple.each_index.select { |i| rare?(tuple[i]) }
  good_tuple = good_idx.map { |i| tuple[i] }
  bad_tuple  = bad_idx.map { |i| tuple[i] }
  good_cues  = cues.is_a?(Array) ? good_idx.map { |i| cues[i] } : cues
  bad_cues   = cues.is_a?(Array) ? bad_idx.map  { |i| cues[i] } : cues

  if(good_tuple.empty?)
    print_half_of_tuple(bad_tuple, focal_word, cues: bad_cues)
  elsif(bad_tuple.empty?)
    print_half_of_tuple(good_tuple, focal_word, cues: good_cues)
  else
    print_half_of_tuple(good_tuple, focal_word, cues: good_cues)
    emit_text " / "
    print_half_of_tuple(bad_tuple, focal_word, cues: bad_cues)
  end
  cgi_print "</p></div>"
  emit_line
  STDOUT.flush unless Thread.current[:html_output_buffer]
end

def print_half_of_tuple(tuple, focal_word=false, cues: nil)
  # print TUPLE separated by slashes
  tuple.each_with_index do |elem, i|
    emit_text " / " if i > 0
    print_word(elem, focal_word, cue: cue_for(cues, i))
  end
end

def print_tuples(tuples, focal_word=false, cues: nil)
  # return boolean, did I print anything? i.e. was TUPLES nonempty?
  success = !tuples.empty?
  if(success)
    tuples.sort.uniq.each { |tuple|
      print_tuple(tuple, focal_word, cues: cues)
    }
  end
  return success
end

def print_words(words, focal_word=false, cue: nil)
  success = !words.empty?
  if(success)
    words.sort.uniq.each { |word|
      cgi_print "<div class='output_tuple'>"
      cgi_print "<p class='output_p'>"
      print_word(word, focal_word, cue: cue)
      if($display_word_frequencies)
        emit_text " (#{frequency(word)})"
      end
      cgi_print "</p>"
      cgi_print "</div>"
      emit_line
    }
  end
  return success
end

def ubiquity(word)
  # 0-255
  result = 0
  case frequency(word)
  when 0
    result = 0
  when 1
    result = 40
  when 2..5
    result = 80
  when 6..20
    result = 120
  when 21..100
    result = 160
  when 101..1000
    result = 200
  else
    result = 255
  end
  result
end

def rare?(word)
  frequency(word) <= RARE_FREQ_MAX
end

def filter_out_rare_words(words)
  # When you enter e.g. 'kitten', you'll get back some reasonable
  # things like 'bitten', 'britain', and 'smitten', but you'll also
  # get back crap like 'bitton', 'brittain', 'brittan', 'brittin',
  # 'britton', 'ditton', 'fitton', etc.
  #
  # Some of these are rare words, and some are just
  # mistakes. Regardless, we don't want them in our output. They
  # clutter up the place and make the good rhymes harder to see.
  #
  # We don't want to get rid of them entirely, though; occasionally
  # that rare word is exactly the one you want, or a good word gets
  # misfiled as rare. So instead we put them in the 'dregs' bucket,
  # which shows up as "For the desperate:" on the website.
  good = words.reject{ |w| rare?(w) }
  bad = words.select { |w| rare?(w) }
  return good, bad
end

def rare_tuple?(tuple, threshold=2)
  common_count = 0
  for word in tuple
    unless rare?(word)
      common_count = common_count + 1
      if(common_count >= threshold)
        return false
      end
    end
  end
  return true
end

def filter_out_rare_tuples(tuples)
  # A tuple gets to be common if it contains at least two common words
  good = tuples.reject{ |t| rare_tuple?(t) }
  bad = tuples.select { |t| rare_tuple?(t) }
  return good, bad
end

def print_word(word, focal_word=false, cue: nil)
  word = word.gsub(/\(.*\)/, '') # remove stuff in parentheses
  got_rhymes = !pronunciations(word).empty?
  # Semantically promiscuous words ("could", "perhaps", "henceforth", ...)
  # get rendered (mostly via the rhymes column) but we strip the click link
  # off them: clicking such a word would land the user on a page where the
  # related/set_related columns short-circuit with the "semantically
  # promiscuous" message in frontend.rb, which is a dead-end UX. Letting
  # them rhyme is fine, but linking them is not. (Unrhymable stop words like
  # "the"/"a"/"you'll" are deleted from word_dict at build time, so they
  # never reach this render path.) The .stop-word CSS class below paints
  # them gray (#bbb); without it they'd
  # inherit the .output_p container's cyan and look identical to clickable
  # links.
  is_promiscuous = semantically_promiscuous?(word)
  link_word = got_rhymes && !is_promiscuous
  # Decided here (not at emit_relatedness_feedback_widget's call site) so the
  # <nobr> wrapper below uses exactly the same predicate as the widget itself
  # — we never want a <nobr> that wraps just the word with no thumbs to glue
  # it to. Predicate matches the original guard verbatim, plus suppression for
  # semantically promiscuous words (no meaningful relatedness vote).
  emit_thumbs = cue && !cue.to_s.empty? && cue != word && !is_promiscuous
  # <nobr> keeps the word + (optional similarity span) + (optional similarity
  # %) + thumbs widget on the same display line. Without it, the inline span
  # for the word and the inline span for .feedback-thumbs are independent
  # break opportunities — the browser will happily land "transparent" at the
  # end of one row and float its 👍👎 onto the next, which reads like an
  # orphan vote control. .feedback-thumbs { white-space: nowrap } already
  # keeps the two thumbs glued to *each other*, so this only adds the
  # outer-tier glue between the word and the widget. <nobr> over a CSS
  # white-space: nowrap wrapper because the user asked for it explicitly
  # and it's understood by every shipping browser; if it ever needs swapping
  # for the standards-track equivalent, the change is span+class right here.
  cgi_print "<nobr>" if emit_thumbs
  if(link_word)
    # @todo urlencode
    cgi_print "<a href='/?word1=#{word}'>"
  end
  # Color the word by its computed relatedness_score to focal_word when one
  # is supplied (e.g. set_related tuples, where every slot should be related
  # to word1). Skipped when focal_word is falsy (word lists that have no
  # single focal, or pair_related tuples whose two slots use different focals).
  # Promiscuous words can never set both branches simultaneously: the
  # set_related rendering path that drives similarity_span short-circuits
  # before print_word when word1 is promiscuous (see compute_column_for_goal),
  # and the rhymes columns that would render a promiscuous word as a result don't
  # set focal_word.
  similarity_span = focal_word && focal_word != "" && word != focal_word
  if similarity_span
    cgi_print "<span style='color: #{word_similarity_color(word, focal_word)}'>"
  elsif is_promiscuous
    cgi_print "<span class='stop-word'>"
  end
  display_word = word.gsub('_', ' ')
  emit_text display_word
  cgi_print "</span>" if similarity_span || is_promiscuous
  if(link_word)
    cgi_print "</a>"
  end
  if($display_word_similarities)
    print_html_percent_similarity(display_word, focal_word)
  end
  # Inline thumbs-up / thumbs-down for relatedness feedback. Suppressed when
  # cue is nil (no relatedness column, e.g. plain rhymes), when the
  # rendered word is the cue itself (relatedness to self is uninteresting), or
  # when the word is semantically promiscuous (thematically_related? treats those
  # pairs as trivially related, so a vote would be meaningless).
  # The data attributes carry the *underscore* surface so what we POST to
  # /feedback matches the shape of curated/related.csv's cue/related
  # columns; feedback.js wires the click → fetch and uses sessionStorage
  # to persist the user's vote across navigations within the tab.
  emit_relatedness_feedback_widget(word, cue) if emit_thumbs
  cgi_print "</nobr>" if emit_thumbs
end

# Inline SVG so the icons inherit color via fill="currentColor" and CSS
# can drive vote-state color (up: #00fa9a, down: #ff355e). Emoji 👍/👎 were
# rejected because their rendering is font-multicolor by default and can't
# be re-tinted to a single brand color without filter hacks.
#
# Base shapes are Google Material's thumb_up / thumb_down (filled),
# adopted because they're the most universally-recognized thumbs silhouette
# and stay readable at our 0.85em inline-with-text size. Both icons are
# tweaked identically: thumb elongated to stick out ~30% farther from the
# palm (9.1u vs Material's 7u), while the palm + forearm geometry stays
# exactly Material's. The viewBox is extended on the thumb-pointing side
# to give the longer tip room to render.
#
# Up-thumb edits (Material path → tweaked):
#   * viewBox 0 0 24 24 → 0 -2 24 26 (headroom ABOVE the icon)
#   * l.95-4.57 (right-side rise into tip apex) → l.95-6.67
#   * L14.17 1 (absolute thumb-tip endpoint) → L14.17 -1.1
#
# Down-thumb is up-thumb rotated 180° about (12, 12), so equivalent edits
# (with directions flipped) are:
#   * viewBox 0 0 24 24 → 0 0 24 26 (headroom BELOW the icon)
#   * l-.95 4.57 (right-side descent into tip apex) → l-.95 6.67
#   * L9.83 23 (absolute thumb-tip endpoint) → L9.83 25.1
#   * l6.59-6.59 (RELATIVE return from tip to palm corner) → l6.59-8.69
#     The return segment is relative in the down path (unlike up, which uses
#     an implicit absolute lineto after L), so its delta has to absorb the
#     additional 2.1u of thumb extension; otherwise the upper-right palm
#     corner would shift along with the tip.
#
# Everything else (forearm rectangle, palm curves, finger fold, lower wrist
# sweep) is byte-for-byte Material's, so both icons still read as the
# Material thumbs — just with more prominent thumbs.
THUMB_UP_SVG = '<svg viewBox="0 -2 24 26" width="1em" height="1em" aria-hidden="true" focusable="false">' \
  '<path fill="currentColor" d="M2 21h4V9H2v12zM23 10c0-1.1-.9-2-2-2h-6.31l.95-6.67.03-.32c0-.41-.17-.79-.44-1.06L14.17 -1.1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-2z"/>' \
  '</svg>'
THUMB_DOWN_SVG = '<svg viewBox="0 0 24 26" width="1em" height="1em" aria-hidden="true" focusable="false">' \
  '<path fill="currentColor" d="M15 3H6c-.83 0-1.54.5-1.84 1.22l-3.02 7.05C1.05 11.5 1 11.74 1 12v2c0 1.1.9 2 2 2h6.31l-.95 6.67-.03.32c0 .41.17.79.44 1.06L9.83 25.1l6.59-8.69C16.78 16.05 17 15.55 17 15V5c0-1.1-.9-2-2-2zm4 0v12h4V3h-4z"/>' \
  '</svg>'

def emit_relatedness_feedback_widget(word, cue)
  c = CGI.escape_html(cue.to_s)
  w = CGI.escape_html(word.to_s)
  # No leading whitespace before <span>: the gap-between-word-and-thumbs is
  # entirely controlled by .feedback-thumbs { margin-left } in CSS, so a
  # textual space would stack on top of that and widen the gap unpredictably.
  cgi_print(
    "<span class='feedback-thumbs' data-cue='#{c}' data-related='#{w}'>" \
    "<button type='button' class='thumb thumb-up' aria-label='thumbs up #{w} as related to #{c}'>#{THUMB_UP_SVG}</button>" \
    "<button type='button' class='thumb thumb-down' aria-label='thumbs down #{w} as related to #{c}'>#{THUMB_DOWN_SVG}</button>" \
    "</span>"
  )
end
