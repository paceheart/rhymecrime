# frozen_string_literal: true

# store.rb — backend-agnostic facade over the precomputed +related#<lemma>+
# table. Picks +DynamoRuntime+ in Lambda (+RHYMECRIME_DATA_SOURCE=dynamodb+)
# and +LocalStore+ (SQLite) everywhere else. The two backends expose the same
# +fetch_related_tuples+ / +find_all_related_precomputed_with_scores+ API so
# +related.rb+ doesn't branch on data source — all it calls is
# +Rhymecrime::Store.foo(...)+.
#
# Loading: +require "rhymecrime/store"+ pulls in +DataSource+ and only the
# backend actually selected; the other gem tree stays unloaded. Keeps Lambda's
# resident set clean of sqlite3 and the dev process clean of aws-sdk.

require_relative "data_source"

module Rhymecrime
  module Store
    module_function

    # The chosen backend (a module / singleton-quacking class that responds to
    # the methods below). Memoized once per process; toggling
    # +RHYMECRIME_DATA_SOURCE+ mid-run won't swap backends.
    def backend
      @backend ||= load_backend
    end

    def load_backend
      if DataSource.dynamodb?
        require_relative "dynamo_store"
        Rhymecrime::DynamoRuntime
      else
        require_relative "local_store"
        Rhymecrime::LocalStore
      end
    end

    # Returns +[[word, score], ...]+ for +related#<lemma_key>+ (empty when
    # missing). Symmetric across backends.
    def fetch_related_tuples(lemma_key)
      backend.fetch_related_tuples(lemma_key)
    end

    def find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
      backend.find_all_related_precomputed_with_scores(lemma_key, include_rhymeless, common_only)
    end

    # True when the backing store is ready to answer queries. DDB is assumed
    # ready (no cheap ping); +LocalStore+ checks that the SQLite file exists.
    # Used by the dev-only compute-pipeline fallback in +related.rb+.
    def available?
      if DataSource.dynamodb?
        true
      else
        backend.available?
      end
    end

    # Cheap existence check for +related#<lemma_key>+. DDB pays for a GetItem;
    # LocalStore does a single indexed EXISTS. Only called from the dev fallback
    # path, so the DDB cost is acceptable — prod never reaches it.
    def has_related?(lemma_key)
      if DataSource.dynamodb?
        !backend.fetch_related_tuples(lemma_key).empty?
      else
        backend.has_related?(lemma_key)
      end
    end
  end
end
