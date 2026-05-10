# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/rhymecrime/build/cmudict_suspect_detectors"
require_relative "../lib/rhymecrime/build/phonology"
require "tempfile"

RSpec.describe CmudictSuspectDetectors do
  def write_cmudict(lines)
    t = Tempfile.new(["cmudict", ".txt"])
    t.write(lines.join("\n") + "\n")
    t.close
    t.path
  end

  describe ".duplicate_alternate_prons" do
    it "flags two variants with identical phones" do
      path = write_cmudict([
                             "PROTOSTAR  P R OW1 D OW0 S T AA1 R",
                             "PROTOSTAR(1)  P R OW1 D OW0 S T AA1 R",
                           ])
      d = described_class.duplicate_alternate_prons(path)
      expect(d.size).to eq(1)
      expect(d[0][:base]).to eq("protostar")
      expect(d[0][:alts]).to eq([0, 1])
    end

    it "ignores comment lines" do
      path = write_cmudict([
                             ";;; comment",
                             "PROTOSTAR  P R OW1 D OW0 S T AA1 R",
                             "PROTOSTAR(1)  P R OW1 D OW0 S T AA1 R",
                           ])
      d = described_class.duplicate_alternate_prons(path)
      expect(d.size).to eq(1)
    end
  end

  describe ".primary_stressed_vowel_ordinal" do
    it "counts vowel ordinals for POTBOILER-style stress" do
      # P AA2 B OY1 L ER0  → primary on second vowel (OY1)
      p = normalize_flat_arphabet_pronunciation(Pronunciation.new(%w[P AA2 B OY1 L ER0]))
      expect(described_class.primary_stressed_vowel_ordinal(p)).to eq(1)
    end

    it "returns 0 when primary is first vowel" do
      p = normalize_flat_arphabet_pronunciation(Pronunciation.new(%w[P AA1 T B OY2 L ER0]))
      expect(described_class.primary_stressed_vowel_ordinal(p)).to eq(0)
    end
  end

  describe ".stress_disagreement_with_kaikki" do
    it "emits when computed rimes differ (e.g. potboiler)" do
      path = write_cmudict(["POTBOILER  P AA2 B OY1 L ER0"])
      kaikki = {
        "potboiler" => [Pronunciation.new(%w[P AA1 T B OY2 L ER0])],
      }
      zipf = { "potboiler" => 4.0 }
      s = described_class.stress_disagreement_with_kaikki(
        path, kaikki, zipf, min_zipf: 3.0, min_word_len: 8, min_vowel_phones: 3, skip_bases: Set.new
      )
      expect(s.size).to eq(1)
      expect(s[0][:cmu_rime]).not_to eq(s[0][:kaikki_rime])
      expect(s[0][:cmu_rime]).to be_a(String)
      expect(s[0][:kaikki_rime]).to be_a(String)
    end

    it "skips when vowel count differs" do
      path = write_cmudict(["POTBOILER  P AA2 B OY1 L ER0"])
      kaikki = {
        "potboiler" => [Pronunciation.new(%w[P AA1 T B OY2])],
      }
      zipf = { "potboiler" => 4.0 }
      s = described_class.stress_disagreement_with_kaikki(
        path, kaikki, zipf, min_zipf: 3.0, min_word_len: 8, min_vowel_phones: 3, skip_bases: Set.new
      )
      expect(s).to be_empty
    end

    it "skips when CMU vs Kaikki only disagree on which syllable gets stress 1 but rime matches (e.g. engineer)" do
      path = write_cmudict(["ENGINEER  EH1 N JH AH0 N IY1 R"])
      kaikki = {
        "engineer" => [Pronunciation.new(%w[EH2 N JH AH0 N IY1 R])],
      }
      zipf = { "engineer" => 4.0 }
      s = described_class.stress_disagreement_with_kaikki(
        path, kaikki, zipf, min_zipf: 3.0, min_word_len: 8, min_vowel_phones: 3, skip_bases: Set.new
      )
      expect(s).to be_empty
    end
  end

  describe ".truncated_or_under_specified_prons" do
    it "flags SEGUE-like short pron for a high-Zipf word" do
      path = write_cmudict(["SEGUE  S EH1 G"])
      zipf = { "segue" => 4.5 }
      t = described_class.truncated_or_under_specified_prons(path, zipf)
      expect(t.any? { |h| h[:base] == "segue" }).to be true
    end
  end

  describe ".single_phone_substitution_vs_kaikki" do
    it "detects T vs D style mismatch" do
      path = write_cmudict(["SATYR  S EY1 D AH0 R"])
      kaikki = {
        "satyr" => [Pronunciation.new(%w[S EY1 T ER0])],
      }
      zipf = { "satyr" => 3.0 }
      u = described_class.single_phone_substitution_vs_kaikki(
        path, kaikki, zipf, min_zipf: 2.5, skip_bases: Set.new
      )
      expect(u.size).to eq(1)
      expect(u[0][:base]).to eq("satyr")
    end
  end
end
