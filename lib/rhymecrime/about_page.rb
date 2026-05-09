# frozen_string_literal: true

require_relative "paths"

module Rhymecrime
  # Full /about.html document: prose in assets/private/about_body.html plus shared attribution
  # strip from credits.html (see frontend#print_html_footer).
  module AboutPage
    BODY_PATH = File.join(ASSETS_PRIVATE_DIR, "about_body.html").freeze
    CREDITS_PATH = File.join(ASSETS_PRIVATE_DIR, "credits.html").freeze

    def self.html
      @html ||= build.freeze
    end

    def self.reload!
      remove_instance_variable(:@html) if instance_variable_defined?(:@html)
    end

    def self.build
      body = IO.read(BODY_PATH, encoding: "UTF-8")
      credits = IO.read(CREDITS_PATH, encoding: "UTF-8")
      body.sub(/\s*<\/body>\s*<\/html>\s*\z/m, "\n#{credits}\n</body>\n</html>\n")
    end
  end
end
