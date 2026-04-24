# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(__dir__, "lib"))

ENV["RHYMECRIME_DATA_SOURCE"] = "dynamodb"
ENV["RHYMECRIME_TABLE_NAME"] ||= ENV.fetch("TABLE_NAME", "rhymecrime")

require "rhymecrime/frontend"

def handler(event:, context:)
  Rhymecrime::DynamoRuntime.clear_session_cache!
  RelatedWords.reset_caches! if defined?(RelatedWords)

  path = event["rawPath"] || event.dig("requestContext", "http", "path") || "/"
  params = event["queryStringParameters"] || {}
  word1 = params["word1"].to_s
  word2 = params["word2"].to_s

  case path
  when "/"
    body = build_rhymecrime_page(word1, word2)
    { statusCode: 200, headers: { "Content-Type" => "text/html; charset=utf-8" }, body: body }
  when "/health"
    begin
      Rhymecrime::DynamoRuntime.client.describe_table(table_name: Rhymecrime::DataSource.table_name)
      { statusCode: 200, headers: { "Content-Type" => "text/plain" }, body: "ok" }
    rescue StandardError => e
      { statusCode: 503, headers: { "Content-Type" => "text/plain" }, body: e.message.to_s }
    end
  else
    { statusCode: 404, headers: { "Content-Type" => "text/plain" }, body: "not found" }
  end
end
