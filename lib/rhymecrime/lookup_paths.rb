# frozen_string_literal: true

require "cgi"
require_relative "route_inventory"

module Rhymecrime
  # Canonical slash-separated URLs for the main RhymeCrime lookup (/cue and /cue/related).
  # Static filenames stay dotted (/feedback.js); path segments must not contain "." so
  # Sinatra/Rack static file serving keeps working alongside regex routes.
  module LookupPaths
    module_function

    def decode_segment(raw)
      CGI.unescapeURIComponent(raw.to_s).encode(
        Encoding::UTF_8,
        Encoding::UTF_8,
        invalid: :replace,
        undef: :replace,
      )
    end

    def reserved_lookup_segment?(decoded_seg)
      Rhymecrime::RouteInventory::RESERVED_SINGLE_SEGMENTS.include?(decoded_seg.downcase)
    end

    # PATH_INFO-style path beginning with "/". Returns [cue, related] strings related-empty ok,
    # or nil if not a lookup path (ambiguous segments, dotted filenames, reserved cue slot).
    def parse_path(request_path)
      return nil unless request_path.is_a?(String)
      return nil unless request_path.start_with?("/")

      tail = request_path.delete_prefix("/")
      return nil if tail.empty?

      segments = tail.split("/")
      return nil if segments.size > 2
      return nil if segments.any?(&:empty?)
      return nil if segments.any? { |s| s.include?(".") }

      w1 = decode_segment(segments[0])
      return nil if reserved_lookup_segment?(w1)

      w2 = segments.size > 1 ? decode_segment(segments[1]) : ""
      [w1, w2]
    end

    def encode_segment(word)
      CGI.escapeURIComponent(
        word.to_s.encode(Encoding::UTF_8, Encoding::UTF_8, invalid: :replace, undef: :replace),
      )
    end

    # Words already normalized (e.g. after parse_query_words): lowercase, stripped, swapped rule applied.
    def lookup_path_from_normalized_words(word1, word2)
      return "/" if word1.empty?

      s1 = encode_segment(word1)
      return "/#{s1}" if word2.empty?

      "/#{s1}/#{encode_segment(word2)}"
    end

  end
end
