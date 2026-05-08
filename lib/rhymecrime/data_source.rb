# frozen_string_literal: true

module Rhymecrime
  module DataSource
    module_function

    # Hot path: lexicon_word_entry in query.rb consults this on every
    # lemma call, and inner loops like RelatedWords.lookup_score_by_lemmas
    # call lemma thousands of times per page render. Memoize on first read —
    # RHYMECRIME_DATA_SOURCE is a process-level config, not a runtime toggle.
    # Specs that mutate ENV between examples should call
    # DataSource.reset_cache!.
    def dynamodb?
      cached = @dynamodb_cached
      return cached unless cached.nil?
      @dynamodb_cached = (ENV["RHYMECRIME_DATA_SOURCE"].to_s.downcase == "dynamodb")
    end

    def reset_cache!
      @dynamodb_cached = nil
    end

    def table_name
      ENV.fetch("TABLE_NAME", "rhymecrime")
    end
  end
end
