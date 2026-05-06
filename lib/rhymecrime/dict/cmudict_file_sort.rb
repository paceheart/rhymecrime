# encoding: utf-8
# frozen_string_literal: true

# CMUdict body sort. Matches upstream 0.7b's order: strip the trailing (n)
# alt-pron marker (if any), then sort by [bare_headword, alt_idx]. ASCII byte
# order on the bare headword handles everything else — possessives, clitics,
# internal apostrophes, hyphens, periods — without special cases:
#
#   ADULTS < ADULTS(1) < ADULTS' < ADULTS'(1)
#   B      < B'GOSH    < B'NAI   < B'RITH   < B'S < B-J < B.
#   WE     < WE'D      < WE'LL   < WE'LL(1) < WE'RE < WE'VE < WED
#
# (n) groups with its base because we sort on the (n)-stripped bare headword
# first and the alt-pron index second; otherwise we'd pick up CMU's own quirk
# ADULTS' (1) inside ADULTS(1) etc.
#
# Apostrophe-like Unicode (U+2018/U+2019/U+2032) is folded to ASCII ' in the
# sort key so a stray smart quote sorts where the ASCII version would.

module CmudictFileSort
  module_function

  # Read the cmudict file as UTF-8. Some upstream CMU rows ship in Latin-1
  # (e.g. DÉJÀ as 44 C9 4A C0); transcode only when the file isn't already
  # valid UTF-8 so we never double-encode by re-running this pipeline.
  def read_text(path)
    raw = File.binread(path)
    text = raw.dup.force_encoding(Encoding::UTF_8)
    return text if text.valid_encoding?

    raw.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
  end

  def headword_from_line(line)
    s = line.chomp
    return "" if s.empty?

    s.split(/\s+/, 2)[0].to_s
  end

  def normalize_headword(headword)
    headword.unicode_normalize(:nfc).tr("\u2018\u2019\u2032", "'")
  end

  # Returns [bare_headword, alt_idx] — bare_headword is the headword with a
  # trailing (n) alt-pron marker stripped.
  def bare_headword(headword)
    h = normalize_headword(headword)
    if (m = h.match(/\A(.)\((\d)\)\z/))
      [m[1], m[2].to_i]
    else
      [h, 0]
    end
  end

  def headword_sort_key(headword)
    bare, alt_idx = bare_headword(headword)
    [bare, alt_idx]
  end

  # Empty lines sort last (should not appear in a clean CMUdict body).
  def body_line_sort_key(line)
    s = line.chomp
    return [1, "", 0] if s.empty?

    [0, *headword_sort_key(headword_from_line(line))]
  end
end
