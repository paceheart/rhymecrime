# frozen_string_literal: true

# Shared ENV parsing for Rhymecrime (strict yes/no lists, CSV override gates, build I/O validate).
module Rhymecrime
  module Env
    STRICT_YES = %w[1 true yes on].freeze
    EXPLICIT_OFF = %w[0 false no off].freeze

    RHYMECRIME_RUN_SKIPPED_ENV = "RHYMECRIME_RUN_SKIPPED"
    RHYMECRIME_VERBOSE_CSV_SWEEP_ENV = "RHYMECRIME_VERBOSE_CSV_SWEEP"
    RELATED_CSV_OVERRIDE_ENV = "RHYMECRIME_RELATED_CSV_OVERRIDE"
    RARITY_CSV_OVERRIDE_ENV = "RHYMECRIME_RARITY_CSV_OVERRIDE"

    module_function

    def strict_truthy?(value)
      v = value.to_s.strip.downcase
      !v.empty? && STRICT_YES.include?(v)
    end

    def explicit_off?(value)
      v = value.to_s.strip.downcase
      !v.empty? && EXPLICIT_OFF.include?(v)
    end

    # RHYMECRIME_BUILD_IO_VALIDATE: unset/blank ⇒ ON; any other non-empty string stays ON
    # unless explicitly off (0 / false / no / off). Matches legacy BuildIo.truthy? semantics.
    def build_io_validate?
      v = ENV["RHYMECRIME_BUILD_IO_VALIDATE"]
      return true if v.nil? || v.to_s.strip.empty?

      !explicit_off?(v)
    end

    # Curated CSV rescues: default ON; set env to exactly "0" to disable.
    def csv_env_override_enabled?(env_var_name)
      ENV[env_var_name].to_s != "0"
    end

    def related_csv_override_enabled?
      csv_env_override_enabled?(RELATED_CSV_OVERRIDE_ENV)
    end

    def rarity_csv_override_enabled?
      csv_env_override_enabled?(RARITY_CSV_OVERRIDE_ENV)
    end

    def run_skipped_examples?
      strict_truthy?(ENV.fetch(RHYMECRIME_RUN_SKIPPED_ENV, ""))
    end

    def verbose_csv_sweep?
      strict_truthy?(ENV.fetch(RHYMECRIME_VERBOSE_CSV_SWEEP_ENV, ""))
    end
  end
end
