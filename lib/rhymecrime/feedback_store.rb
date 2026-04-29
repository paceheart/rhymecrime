# frozen_string_literal: true

# feedback_store.rb — write-only sink for per-(cue, related) thumbs feedback
# collected from the live UI. Two backends, picked at request time by
# +Rhymecrime::DataSource.dynamodb?+:
#
#   * +DynamoFeedbackStore+ — production. Writes one item per click into a
#     dedicated +rhymecrime-feedback+ table (see +template.yaml+).
#       pk = "feedback#<cue>#<related>"
#       sk = ISO 8601 timestamp with sub-second precision
#       attrs = verdict, ip, user_agent, session
#     The (pk, sk) layout means we can +Query+ for "every vote on this pair"
#     in one call (sort-key range over time), and +Scan+ the table so
#     +bin/augment-related-from-feedback+ (DynamoDB by default; +--from-file+
#     for local CSV) can fold feedback into +curated/related.csv+ when re-importing training data.
#
#   * +CsvFeedbackStore+ — local dev. Appends a row to
#     +generated/feedback.csv+ on every click. Same column set as the
#     DDB attrs so importer scripts can ingest either source.
#
# Why a separate table from the read-only +rhymecrime+ main store: the Lambda
# function's IAM policy is +DynamoDBReadPolicy+ on the main table by design
# (smallest possible blast radius if the function is hijacked). Feedback
# writes go to a different physical table with a +DynamoDBCrudPolicy+ scoped
# to *that* table only — write capability stays surgical and the main read
# path keeps its read-only policy.

require "csv"
require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "data_source"

module Rhymecrime
  module FeedbackStore
    module_function

    # +up+/+down+: the user expressed a verdict on the (cue, related) pair.
    # +undo+: the user clicked their already-active thumb, retracting it.
    # We keep +undo+ in the audit trail (rather than just deleting the prior
    # row) so importer scripts can reconstruct the full click sequence and
    # distinguish "user retracted" from "user never voted" — useful if we
    # want to weight retracted votes differently when training, or surface
    # ambivalence in disagreement-resolution UIs.
    #
    # +uncomputed+: not a user-driven click. Logged by the runtime when a
    # +set_related+ request lands on a cue that has no precomputed
    # +set_related#<lemma>+ row in the authoritative store (i.e. it's
    # outside the cue universe +bin/precompute-set-related+ covered).
    # See +record_uncomputed_cue!+ below; the +"[uncomputed]"+ marker
    # sentinel goes in the +related+ column so importers can grep
    # +pk = "feedback#<cue>#[uncomputed]"+ to surface the long tail of
    # cues users actually ask about, and feed that list to the next
    # precompute round.
    VALID_VERDICTS = %w[up down undo uncomputed].freeze

    # Sentinel placed in the +related+ slot of an +uncomputed+-verdict row.
    # Bracketed so it can never collide with a real headword (no real
    # vocabulary item starts with +[+) and is trivially grep-friendly when
    # exporting feedback for the next precompute pass.
    UNCOMPUTED_RELATED_TOKEN = "[uncomputed]"

    # Top-level entry point. Returns true on success, false on a (logged)
    # write failure — the UI treats either as "click registered" so a flaky
    # backend doesn't surface as a user-facing error during data collection.
    #
    # +cue+ / +related+ are the lowercased surface forms that were rendered
    # next to the thumbs (matching the conventions in +curated/related.csv+'s
    # +cue+ / +related+ columns). +verdict+ is +"up"+ or +"down"+. +ip+,
    # +user_agent+, +session+ are request-scoped metadata pulled from the
    # caller (Sinatra +request.*+ in dev, Lambda +event["requestContext"]+
    # in prod) — nil-safe; absent metadata is stored as the empty string so
    # downstream importers don't have to handle nils.
    def record!(cue:, related:, verdict:, ip: nil, user_agent: nil, session: nil)
      cue = cue.to_s.strip.downcase
      related = related.to_s.strip.downcase
      verdict = verdict.to_s.strip.downcase
      return false if cue.empty? || related.empty?
      return false unless VALID_VERDICTS.include?(verdict)

      record = {
        timestamp: Time.now.utc.iso8601(3),
        cue: cue,
        related: related,
        verdict: verdict,
        ip: ip.to_s,
        user_agent: user_agent.to_s,
        session: session.to_s,
      }

      backend.record!(record)
      true
    rescue StandardError => e
      warn "feedback_store: dropped #{cue.inspect}/#{related.inspect}=#{verdict.inspect}: #{e.class}: #{e.message}"
      false
    end

    # Log an "uncomputed cue" event — the runtime asked +Store.fetch_set_
    # related_tuples+ for a cue that has no precomputed row, so the user
    # got the friendly "Oops, I don't know what words are related to X,
    # sorry! I'll make a note." message in +crime.rb+'s +set_related+
    # goal dispatch. The "make a note" half of that message is literally
    # this call: it emits one feedback row whose +cue+ is the user's
    # surface input and whose +related+ slot is +UNCOMPUTED_RELATED_TOKEN+,
    # so a follow-up +bin/augment-related-from-feedback+ run (default:
    # DynamoDB; +--from-file+ for local) can rank the most-asked-about uncomputed cues and add them to the next precompute round's cue
    # universe.
    #
    # Soft-fails by design (mirrors +record!+'s rescue): a flaky feedback
    # backend should not surface as a 500 on the user-visible
    # +set_related+ response, which already has a graceful copy path. The
    # row is best-effort observability, not part of the contract.
    def record_uncomputed_cue!(cue:, ip: nil, user_agent: nil, session: nil)
      record!(
        cue: cue,
        related: UNCOMPUTED_RELATED_TOKEN,
        verdict: "uncomputed",
        ip: ip,
        user_agent: user_agent,
        session: session,
      )
    end

    def backend
      @backend ||= DataSource.dynamodb? ? DynamoFeedbackStore.new : CsvFeedbackStore.new
    end

    # Test seam: spec helpers can swap in a fake. +reset_backend!+ also lets
    # any test that mutates +ENV["RHYMECRIME_DATA_SOURCE"]+ between examples
    # pick up the change (matches +DataSource.reset_cache!+'s contract).
    def backend=(b)
      @backend = b
    end

    def reset_backend!
      @backend = nil
    end

    # Canonical feedback-table name. Defaults to +"<main>-feedback"+ so
    # SAM's +TableName+ parameter suffices to derive both. Override with
    # +RHYMECRIME_FEEDBACK_TABLE_NAME+ at the env layer when the convention
    # doesn't fit (e.g. shared-account naming policies).
    def feedback_table_name
      ENV["RHYMECRIME_FEEDBACK_TABLE_NAME"] || "#{DataSource.table_name}-feedback"
    end

    # CSV-backed dev sink. Appends one row per click, with a header line on
    # first write so the file is +CSV.parse+-ready without external schema.
    # File-locked to keep parallel Sinatra worker threads from interleaving
    # bytes mid-row; +flock+ is a no-op on the +ext4+/+APFS+ paths we ship
    # against but cheap insurance.
    class CsvFeedbackStore
      HEADER = %w[timestamp cue related verdict ip user_agent session].freeze

      def initialize(path = nil)
        @path = path || default_path
      end

      def record!(record)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |f|
          f.flock(File::LOCK_EX)
          f.puts(HEADER.to_csv) if f.size.zero?
          f.puts(HEADER.map { |k| record[k.to_sym] }.to_csv)
          f.flock(File::LOCK_UN)
        end
      end

      def path
        @path
      end

      private

      def default_path
        # Late-bound: +generated_dict_path+ lives in +utils_rhyme+, which
        # the Lambda runtime path doesn't load. We're only ever instantiated
        # in dev, so the require here is safe.
        require_relative "dict/utils_rhyme"
        generated_dict_path("feedback.csv")
      end
    end

    # DynamoDB-backed prod sink. One +put_item+ per click. Lazy-loads the
    # SDK / client so the dev path doesn't pay the +aws-sdk-dynamodb+ import
    # cost just to write a CSV.
    class DynamoFeedbackStore
      def initialize(table_name: nil, client: nil)
        @table_name = table_name || FeedbackStore.feedback_table_name
        @client = client
      end

      def record!(record)
        client.put_item(
          table_name: @table_name,
          item: {
            "pk" => "feedback##{record[:cue]}##{record[:related]}",
            "sk" => record[:timestamp],
            "verdict" => record[:verdict],
            "ip" => record[:ip],
            "user_agent" => record[:user_agent],
            "session" => record[:session],
          }
        )
      end

      private

      def client
        @client ||= begin
          require "aws-sdk-dynamodb"
          Aws::DynamoDB::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
        end
      end
    end
  end
end
