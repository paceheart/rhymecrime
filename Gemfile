# frozen_string_literal: true

source "https://rubygems.org"

gem "aws-sdk-dynamodb"
gem "memery"
gem "msgpack"
gem "puma"
gem "rwordnet"
gem "sinatra"
gem "sqlite3"

group :development, :test do
  gem "csv"
  gem "numo-narray" # BLAS-backed dot products for the MPNet sense-vector
                    # cosines in +lib/rhymecrime/relatedness/signals.rb+.
                    # Offline / local-dev only — signals.rb isn't loaded at
                    # Lambda runtime (see +lib/rhymecrime/related.rb+).
  gem "rack-test"
  gem "rspec"
end
