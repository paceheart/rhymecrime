# frozen_string_literal: true

require_relative "paths"

module Rhymecrime
  # Paths and segments that interact with (or would collide with) bare segment URLs
  # such as /<cue> and /<cue>/<related>, assuming cue words do not contain "." .
  #
  # Production stack (template.yaml + lambda_handler.rb):
  # - GET /            — splash only (word1/word2 query params ignored).
  # - GET /<cue>, GET /<cue>/<related> — canonical lookup URLs (Rhymecrime::LookupPaths).
  # - GET Rhymecrime::HttpPaths::HEALTH — Dynamo describe_table probe; segment "_health".
  # - POST Rhymecrime::HttpPaths::FEEDBACK — JSON feedback API (GET hits GET /{proxy+} → Lambda 404
  #                      unless routed as word pages later).
  # - GET /{proxy+}    — catch-all GET; Lambda serves only ASSET_ROUTES keys, else 404.
  #
  # Lambda ASSET_ROUTES (lambda_handler.rb): /robots.txt, /crimestyle.css,
  # /crimestyle_wide.css, /feedback.js, /about.html — each final segment contains ".", so they cannot
  # equal a dot-free dictionary word used as /:word.
  #
  # Local Sinatra (app.rb) additionally defines GET /similar (not wired in template.yaml).
  # On production, /similar is not an API route and LookupPaths rejects that first segment for /<cue>.
  #
  # Sinatra sets public_folder to assets/: dotted URLs only for browser assets.
  # Composition fragments live under assets/private/ (blocked as /private/* locally; see config.ru).
  module RouteInventory
    # Path segments reserved by system routes (underscore-prefixed URLs avoid lexicon words).
    RESERVED_SINGLE_SEGMENTS = [
      Rhymecrime::HttpPaths::HEALTH.delete_prefix("/"),
      Rhymecrime::HttpPaths::FEEDBACK.delete_prefix("/"),
      "similar",
    ].freeze
  end
end
