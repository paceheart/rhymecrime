# frozen_string_literal: true

source "https://rubygems.org"

# Match AWS Lambda's ruby3.4 managed runtime (see template.yaml).
# Pessimistic on minor so a contributor on 3.5/4.0 surfaces the mismatch
# before deploy instead of after; AWS picks the patch within the 3.4.x line.
ruby "~> 3.4.0"

gem "aws-sdk-dynamodb"
gem "csv"     # bundled (not default) since Ruby 3.4 — required at runtime
              # by lib/rhymecrime/feedback_store.rb's CsvFeedbackStore.
gem "memery"
gem "msgpack"
gem "puma"
gem "rwordnet"
gem "sinatra"
gem "sqlite3"

group :development, :test do
  gem "aws-sdk-sts" # bin/upload-to-dynamodb pre-flight: GetCallerIdentity
                    # prints the resolved account+ARN before any BatchWrite
                    # so a wrong AWS_PROFILE surfaces immediately. Lambda
                    # runtime never touches STS; keeping this out of the main
                    # group keeps it out of the deployment bundle.
  gem "rexml"       # Ruby 3.4 demoted rexml from default-gem to bundled-gem,
                    # which means bundle exec won't auto-load it. aws-sdk-sts
                    # uses Query (XML) protocol and falls over on first call
                    # without one of {rexml, ox, oga, libxml, nokogiri}. Pure-Ruby
                    # rexml is the lightest option and has no native build step.
                    # Dev/test only — aws-sdk-dynamodb (Lambda runtime) speaks
                    # JSON, so the prod bundle still doesn't pull this in.
  gem "numo-narray" # BLAS-backed dot products for the MPNet sense-vector
                    # cosines in lib/rhymecrime/relatedness/signals.rb.
                    # Offline / local-dev only — signals.rb isn't loaded at
                    # Lambda runtime (see lib/rhymecrime/related.rb).
  gem "parallel_tests" # bundle exec parallel_rspec spec/ partitions spec
                       # files across worker processes (one per core by default).
                       # Each worker pays the boot cost (~22s of msgpack parsing
                       # in require "rhymecrime/crime") once, then the slow
                       # similar_rhymes_* describe blocks fan out — see the
                       # spec/similar_rhymes_{set_related,pair_related,related_
                       # rhymes}_spec.rb split. Dev/test only.
  gem "rack-test"
  gem "rspec"
  gem "stackprof" # CPU sampling profiler. Used ad-hoc via:
                  #   STACKPROF_OUT=tmp/p.dump bundle exec ruby -rstackprof ...
                  # Dev/test only.
end
