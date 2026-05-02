# frozen_string_literal: true

# Inspect one headword across RhymeCrime corpora and generated artifacts.
#
#   ruby -I lib -e 'require "rhymecrime/audit_word"; audit_word("washington")'
#   Rhymecrime.audit_word("pirate", io: $stderr)
#
require_relative "../rhymecrime"
require "json"
require "msgpack"
require "open3"

require_relative "dict/phoneme"
require_relative "dict/pronunciation"
require_relative "dict/utils_rhyme"

module Rhymecrime
  module AuditWord
    CORPORA = File.join(Rhymecrime::ROOT, "corpora").freeze
    GENERATED = File.join(Rhymecrime::ROOT, "generated").freeze
    # Max lines to print per gzip from zgrep (-m); keeps audit output bounded.
    WIKT_ZGREP_MAX_LINES = 25

    module_function

    def audit_word(word, io: $stdout)
      raw = word.to_s
      w = raw.downcase.strip
      if w.empty?
        io.puts "audit_word: empty string"
        return
      end

      io.puts "=== Rhymecrime::audit_word #{w.inspect} (repo #{Rhymecrime::ROOT}) ==="
      io.puts

      # --- Lexicon / runtime helpers (no full crime.rb) ---
      io.puts "--- Spelling / policy ---"
      if explicitly_forbidden?(w)
        if non_ascii_only?(w)
          io.puts "explicitly_forbidden?: TRUE (non_ascii_only? — every character is non-ASCII)"
        else
          io.puts "explicitly_forbidden?: TRUE (rarity.csv: LISTED forbidden/forbidden_ish)"
        end
      else
        io.puts "explicitly_forbidden?: FALSE (not in rarity.csv forbidden rows; not non_ascii_only?)"
      end
      if unrhymable_stop_word?(w)
        io.puts "unrhymable_stop_words.txt: LISTED (deleted from word_dict at build time)"
      else
        io.puts "unrhymable_stop_words.txt: not listed"
      end
      if semantically_promiscuous?(w)
        io.puts "semantically_promiscuous.txt: LISTED (kept as headword; relatedness short-circuits)"
      else
        io.puts "semantically_promiscuous.txt: not listed"
      end
      begin
        pf = preferred_form(w)
        io.puts "preferred_form: #{pf.inspect}#{pf == w ? '' : " (input was #{w.inspect})"}"
      rescue StandardError => e
        io.puts "preferred_form: error #{e.class}: #{e.message}"
      end
      vf = variants[w]
      if vf
        io.puts "spelling.csv: #{vf.inspect}"
      else
        io.puts "curated/spelling.csv: no row for this key (variants()[#{w.inspect}] is nil)"
      end
      io.puts

      # --- generated/word_dict.txt ---
      wd_path = generated_dict_path(WORD_DICT_FILENAME)
      wd_line = find_word_dict_line(wd_path, w)
      if wd_line
        io.puts "--- #{WORD_DICT_FILENAME} ---"
        io.puts "present: yes"
        parts = wd_line.split(",", 3)
        freq = parts[1].to_i
        io.puts "frequency column: #{freq}"
        io.puts "raw line (truncated): #{wd_line[0, 200]}#{wd_line.size > 200 ? '...' : ''}"
      else
        io.puts "--- #{WORD_DICT_FILENAME} ---"
        io.puts "generated corpus #{WORD_DICT_FILENAME.inspect} lacks word #{w.inspect}"
      end
      io.puts

      # --- generated/part_of_speech.json ---
      pos_path = generated_dict_path(PART_OF_SPEECH_FILENAME)
      if File.exist?(pos_path)
        pos_map = JSON.parse(File.read(pos_path, encoding: "UTF-8"))
        tags = pos_map[w]
        if tags
          io.puts "--- #{PART_OF_SPEECH_FILENAME} ---"
          io.puts "present: yes -> #{tags.inspect}"
        else
          io.puts "--- #{PART_OF_SPEECH_FILENAME} ---"
          io.puts "generated corpus #{PART_OF_SPEECH_FILENAME.inspect} lacks word #{w.inspect}"
        end
      else
        io.puts "--- #{PART_OF_SPEECH_FILENAME} ---"
        io.puts "file missing: #{pos_path}"
      end
      io.puts

      # --- generated/hyphen_variant_map.json ---
      hyp_path = generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
      if File.exist?(hyp_path)
        hyp = JSON.parse(File.read(hyp_path, encoding: "UTF-8"))
        folds = hyp.select { |_fold, forms| forms.is_a?(Array) && forms.include?(w) }
        if hyp.key?(w)
          io.puts "--- #{HYPHEN_VARIANT_MAP_FILENAME} ---"
          io.puts "present: as fold key -> #{hyp[w].inspect}"
        elsif folds.any?
          io.puts "--- #{HYPHEN_VARIANT_MAP_FILENAME} ---"
          io.puts "present: in folds #{folds.keys.sort.inspect}"
        else
          io.puts "--- #{HYPHEN_VARIANT_MAP_FILENAME} ---"
          io.puts "generated corpus #{HYPHEN_VARIANT_MAP_FILENAME.inspect} has no fold containing #{w.inspect}"
        end
      else
        io.puts "--- #{HYPHEN_VARIANT_MAP_FILENAME} ---"
        io.puts "file missing: #{hyp_path}"
      end
      io.puts

      # --- generated/rime_dict.txt (streaming) ---
      rime_path = generated_dict_path(RIME_DICT_FILENAME)
      if File.exist?(rime_path)
        rimes = rime_buckets_containing_word(rime_path, w)
        if rimes.any?
          io.puts "--- #{RIME_DICT_FILENAME} ---"
          io.puts "present: yes in bucket(s) rime=#{rimes_list(rimes)}"
        else
          io.puts "--- #{RIME_DICT_FILENAME} ---"
          io.puts "generated corpus #{RIME_DICT_FILENAME.inspect} has no rime line listing #{w.inspect}"
        end
      else
        io.puts "--- #{RIME_DICT_FILENAME} ---"
        io.puts "file missing: #{rime_path}"
      end
      io.puts

      # --- generated/numberbatch_vectors.msgpack ---
      nb_path = generated_dict_path(NUMBERBATCH_VECTORS_FILENAME)
      if File.exist?(nb_path)
        nb = MessagePack.unpack(File.binread(nb_path))
        vec = nb[hyphens_to_underscores(w)]
        if vec
          io.puts "--- #{NUMBERBATCH_VECTORS_FILENAME} ---"
          io.puts "present: yes (dim=#{vec.size})"
        else
          io.puts "--- #{NUMBERBATCH_VECTORS_FILENAME} ---"
          io.puts "generated corpus #{NUMBERBATCH_VECTORS_FILENAME.inspect} lacks word #{w.inspect}"
        end
      else
        io.puts "--- #{NUMBERBATCH_VECTORS_FILENAME} ---"
        io.puts "file missing: #{nb_path}"
      end
      io.puts

      # --- generated/conceptnet_edges.json ---
      cn_path = generated_dict_path(CONCEPTNET_EDGES_FILENAME)
      if File.exist?(cn_path)
        edges = JSON.parse(File.read(cn_path, encoding: "UTF-8"))
        cnw = hyphens_to_underscores(w)
        hits = edges.keys.select { |k| k.split("|").include?(w) || k.split("|").include?(cnw) }
        if hits.any?
          sample = hits.first(8)
          io.puts "--- #{CONCEPTNET_EDGES_FILENAME} ---"
          io.puts "present: #{hits.size} edge key(s); sample: #{sample.inspect}"
        else
          io.puts "--- #{CONCEPTNET_EDGES_FILENAME} ---"
          io.puts "generated corpus #{CONCEPTNET_EDGES_FILENAME.inspect} has no edge key containing #{w.inspect}"
        end
      else
        io.puts "--- #{CONCEPTNET_EDGES_FILENAME} ---"
        io.puts "file missing: #{cn_path}"
      end
      io.puts

      # --- generated/usf_associations.json ---
      usf_path = generated_dict_path(USF_ASSOCIATIONS_FILENAME)
      if File.exist?(usf_path)
        ua = JSON.parse(File.read(usf_path, encoding: "UTF-8"))
        as_cue = ua[w]
        target_hits = 0
        ua.each_value do |targets|
          next unless targets.is_a?(Hash)
          target_hits += 1 if targets.key?(w)
        end
        io.puts "--- #{USF_ASSOCIATIONS_FILENAME} ---"
        if as_cue
          n = as_cue.is_a?(Hash) ? as_cue.size : 0
          io.puts "as cue: yes (#{n} targets)"
        else
          io.puts "as cue: no (generated #{USF_ASSOCIATIONS_FILENAME.inspect} has no cue #{w.inspect})"
        end
        if target_hits.positive?
          io.puts "as target: yes (#{target_hits} cue(s) list this word)"
        else
          io.puts "as target: no (no cue→target row for #{w.inspect} in #{USF_ASSOCIATIONS_FILENAME.inspect})"
        end
      else
        io.puts "--- #{USF_ASSOCIATIONS_FILENAME} ---"
        io.puts "file missing: #{usf_path}"
      end
      io.puts

      # --- generated/wordfreq.tsv ---
      wf_path = File.join(GENERATED, "wordfreq.tsv")
      zipf = tsv_first_column_lookup(wf_path, w)
      io.puts "--- wordfreq.tsv ---"
      if zipf
        io.puts "present: yes (Zipf #{zipf})"
      elsif File.exist?(wf_path)
        io.puts "generated corpus wordfreq.tsv lacks word #{w.inspect}"
      else
        io.puts "file missing: #{wf_path}"
      end
      io.puts

      # --- corpora/cmudict ---
      cmu = File.join(CORPORA, "cmudict", "cmudict-0.7c.txt")
      io.puts "--- cmudict (corpus) ---"
      if File.exist?(cmu)
        lines = cmudict_lines_for_word(cmu, w)
        if lines.any?
          io.puts "present: #{lines.size} line(s); first: #{lines.first[0, 120]}#{lines.first.size > 120 ? '...' : ''}"
        else
          io.puts "corpus #{cmu.inspect} lacks word #{w.upcase.inspect} (as CMU headword)"
        end
      else
        io.puts "file missing: #{cmu}"
      end
      io.puts

      # --- corpora/subtlex ---
      sub = File.join(CORPORA, "subtlex", "SUBTLEXus.tsv")
      io.puts "--- SUBTLEXus.tsv (corpus) ---"
      if File.exist?(sub)
        row = subtlex_row_for_word(sub, w)
        if row
          io.puts "present: yes -> #{row[0, 3].join("\t")} ..."
        else
          io.puts "corpus #{sub.inspect} lacks word #{w.inspect} (Word column)"
        end
      else
        io.puts "file missing: #{sub}"
      end
      io.puts

      # --- WordNet ---
      io.puts "--- WordNet (corpus) ---"
      wn_dir = File.join(CORPORA, "wordnet", "3.1")
      if File.directory?(wn_dir)
        begin
          require "rwordnet"
          WordNet::DB.path = wn_dir
          lemmas = WordNet::Lemma.find_all(w)
          if lemmas.any?
            io.puts "present: yes (#{lemmas.size} lemma(s))"
          else
            io.puts "corpus WordNet 3.1 lacks lemma #{w.inspect}"
          end
        rescue LoadError
          io.puts "skipped: gem rwordnet not available"
        end
      else
        io.puts "directory missing: #{wn_dir}"
      end
      io.puts

      # --- USF raw shards (optional) ---
      io.puts "--- USF raw Cue_Target_Pairs.* (corpus) ---"
      usf_dir = File.join(CORPORA, "usf")
      if File.directory?(usf_dir)
        cue_rows = 0
        target_rows = 0
        Dir.glob(File.join(usf_dir, "Cue_Target_Pairs.*")).sort.each do |path|
          File.foreach(path, encoding: "UTF-8") do |line|
            line = line.scrub
            next if line.include?("CUE,")
            next unless line.match?(/\A[A-Z]/)
            cue, target = line.split(",", 3).values_at(0, 1)
            next unless cue && target
            cue_rows += 1 if cue.strip.casecmp?(w)
            target_rows += 1 if target.strip.downcase == w
          end
        end
        io.puts "cue rows (uppercase match): #{cue_rows}"
        io.puts "target rows (exact lower match on 2nd field): #{target_rows}"
      else
        io.puts "directory missing: #{usf_dir}"
      end
      io.puts

      # --- Kaikki / Wiktionary extracts (zgrep in .gz) ---
      io.puts "--- Wiktionary / Kaikki extracts (corpus) ---"
      %w[
        wiktionary/kaikki-english-filtered.jsonl.gz
        wiktionary/enwiktionary.jsonl.gz
      ].each do |rel|
        p = File.join(CORPORA, rel)
        unless File.exist?(p)
          io.puts "#{rel}: absent"
          next
        end
        io.puts "#{rel}: (#{File.size(p)} bytes)"
        wiktionary_zgrep(io, w, p, WIKT_ZGREP_MAX_LINES)
      end
      io.puts

      # --- ConceptNet source gzip (presence only) ---
      io.puts "--- ConceptNet assertions (corpus, optional) ---"
      %w[
        corpora/conceptnet/conceptnet-assertions-5.7.0.csv.gz
        conceptnet-assertions-5.7.0.csv.gz
      ].map { |rel| File.join(Rhymecrime::ROOT, rel) }.each do |p|
        io.puts "#{p}: #{File.exist?(p) ? 'present' : 'absent'}"
      end
      io.puts
      io.puts "=== end audit_word #{w.inspect} ==="
    end

    def wiktionary_zgrep(io, word, gz_path, max_lines)
      stdout, stderr, status = Open3.capture3(
        "zgrep", "-F", "-n", "-m", max_lines.to_s, word, gz_path
      )
      err = stderr.to_s.strip
      io.puts "  zgrep stderr: #{err}" unless err.empty?
      case status.exitstatus
      when 0
        lines = stdout.lines.map(&:chomp).reject(&:empty?)
        if lines.empty?
          io.puts "  zgrep: exit 0 but no output"
        else
          io.puts "  zgrep: first #{lines.size} line(s) (fixed-string #{word.inspect}, -m #{max_lines}):"
          lines.each { |ln| io.puts "    #{ln}" }
          io.puts "  (truncated by -m #{max_lines}; more matches may exist)" if lines.size >= max_lines
        end
      when 1
        io.puts "  zgrep: no match for fixed string #{word.inspect}"
      else
        io.puts "  zgrep: failed (exit #{status.exitstatus})#{err.empty? ? '' : ": #{err}"}"
      end
    rescue Errno::ENOENT => e
      io.puts "  zgrep: could not run (#{e.message})"
    end

    def rimes_list(rimes)
      rimes.size > 6 ? "#{rimes.first(6).join(', ')}, ... (#{rimes.size} total)" : rimes.join(", ")
    end

    def find_word_dict_line(path, w)
      return nil unless File.exist?(path)

      IO.foreach(path, encoding: "UTF-8") do |line|
        next unless useful_line?(line)
        tok = line.split(",", 2).first
        next if tok.nil? || tok.empty?
        return line.chomp if tok.desanitize == w
      end
      nil
    end

    def rime_buckets_containing_word(path, w)
      found = []
      IO.foreach(path, encoding: "UTF-8") do |line|
        next unless useful_line?(line)
        fields = line.split
        next if fields.size < 2
        rime = fields[0]
        words = fields[1..-1].map(&:desanitize)
        found << rime if words.include?(w)
      end
      found.uniq
    end

    def tsv_first_column_lookup(path, w)
      return nil unless File.exist?(path)

      IO.foreach(path, encoding: "UTF-8") do |line|
        col = line.split("\t", 2).first
        return line.split("\t")[1].to_f if col == w
      end
      nil
    end

    def cmudict_lines_for_word(path, w)
      u = w.upcase
      lines = []
      IO.foreach(path, encoding: "UTF-8") do |line|
        next if line.start_with?(";;;")
        next unless line.start_with?(u)
        # CMU: WORD  ARPABET... or WORD(#)  ...
        next unless line.match?(/\A#{Regexp.escape(u)}(\(\d+\))? /)
        lines << line.chomp
      end
      lines
    end

    def subtlex_row_for_word(path, w)
      IO.foreach(path, encoding: "UTF-8") do |line|
        next if line.start_with?("Word\t")
        col = line.split("\t", 2).first
        next unless col
        return line.chomp.split("\t") if col.casecmp(w).zero?
      end
      nil
    end
  end

  def self.audit_word(word, io: $stdout)
    AuditWord.audit_word(word, io: io)
  end
end

def audit_word(word, io = $stdout)
  Rhymecrime.audit_word(word, io: io)
end
