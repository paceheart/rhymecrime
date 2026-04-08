#!/usr/bin/env ruby
# Thin wrapper for deployments that expect rhyme.rb at the repo root (e.g. CGI).
load File.expand_path("bin/rhyme.rb", __dir__)
