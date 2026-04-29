# frozen_string_literal: true

# Coverage for the +Rhymecrime::FeedbackStore+ "uncomputed cue" path —
# the runtime call site in +crime.rb+'s +set_related+ goal dispatch logs
# a feedback row whenever +Store.fetch_set_related_tuples+ misses on an
# authoritative store, so a follow-up export step can surface the most-
# asked-about cues outside the precomputed universe and feed them to
# the next +bin/precompute-set-related+ run.
#
# The user-driven thumbs-feedback path (+up+/+down+/+undo+) goes through
# the same +record!+ entry point and is exercised end-to-end by the
# Sinatra / Lambda integration; this spec focuses on the verdict shape
# and the +UNCOMPUTED_RELATED_TOKEN+ sentinel that distinguishes
# uncomputed rows from real votes.

require_relative "spec_helper"
require "rhymecrime/feedback_store"

RSpec.describe Rhymecrime::FeedbackStore do
  # Fake backend with the same +record!(record)+ shape as +Csv+/
  # +Dynamo+FeedbackStore+. Captures everything written to it for
  # assertion. Reset_backend! brings the real one back after each
  # example so we don't leak the fake into a later run.
  let(:fake_backend) do
    Class.new do
      attr_reader :records

      def initialize
        @records = []
      end

      def record!(record)
        @records << record
      end
    end.new
  end

  before { described_class.backend = fake_backend }
  after  { described_class.reset_backend! }

  describe ".record_uncomputed_cue!" do
    it "writes one row with the documented (cue, related, verdict) shape" do
      ok = described_class.record_uncomputed_cue!(cue: "obscure_word")

      expect(ok).to be true
      expect(fake_backend.records.size).to eq(1)
      record = fake_backend.records.first
      expect(record).to include(
        cue: "obscure_word",
        related: described_class::UNCOMPUTED_RELATED_TOKEN,
        verdict: "uncomputed",
      )
      expect(record[:timestamp]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it "lowercases and strips the cue (matches the user-driven path)" do
      described_class.record_uncomputed_cue!(cue: "  RareWord  ")

      expect(fake_backend.records.first[:cue]).to eq("rareword")
    end

    it "drops empty cues silently" do
      ok = described_class.record_uncomputed_cue!(cue: "   ")

      expect(ok).to be false
      expect(fake_backend.records).to be_empty
    end

    it "passes through optional ip / user_agent / session metadata" do
      described_class.record_uncomputed_cue!(
        cue: "obscure_word",
        ip: "203.0.113.7",
        user_agent: "Mozilla/5.0",
        session: "sess-abc",
      )

      record = fake_backend.records.first
      expect(record).to include(ip: "203.0.113.7", user_agent: "Mozilla/5.0", session: "sess-abc")
    end

    it "soft-fails when the backend raises (a flaky writer must not 500 the user response)" do
      allow(fake_backend).to receive(:record!).and_raise(StandardError, "boom")

      expect { described_class.record_uncomputed_cue!(cue: "obscure_word") }.not_to raise_error
    end
  end

  describe "VALID_VERDICTS" do
    it "includes the uncomputed verdict alongside the user-driven ones" do
      # Order/contents matter for the +record!+ guard — adding +uncomputed+
      # without listing it here would silently drop every uncomputed-cue
      # log to the +unless VALID_VERDICTS.include?(verdict)+ check.
      expect(described_class::VALID_VERDICTS).to include("up", "down", "undo", "uncomputed")
    end
  end
end
