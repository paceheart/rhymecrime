# frozen_string_literal: true

module Rhymecrime
  module DataSource
    module_function

    def dynamodb?
      ENV["RHYMECRIME_DATA_SOURCE"].to_s.downcase == "dynamodb"
    end

    def table_name
      ENV.fetch("RHYMECRIME_TABLE_NAME", "rhymecrime")
    end
  end
end
