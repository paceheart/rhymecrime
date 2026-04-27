# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(__dir__, "lib"))

ENV["RHYMECRIME_DATA_SOURCE"] = "dynamodb"
ENV["RHYMECRIME_TABLE_NAME"] ||= ENV.fetch("TABLE_NAME", "rhymecrime")

require "base64"
require "json"
require "rhymecrime/frontend"
require "rhymecrime/feedback_store"

def handler(event:, context:)
  Rhymecrime::DynamoRuntime.clear_session_cache!
  RelatedWords.reset_caches! if defined?(RelatedWords)

  path = event["rawPath"] || event.dig("requestContext", "http", "path") || "/"
  method = event.dig("requestContext", "http", "method") || "GET"
  params = event["queryStringParameters"] || {}
  word1 = params["word1"].to_s
  word2 = params["word2"].to_s

  case [method, path]
  when ["GET", "/"]
    body = build_rhymecrime_page(word1, word2)
    { statusCode: 200, headers: { "Content-Type" => "text/html; charset=utf-8" }, body: body }
  when ["GET", "/health"]
    begin
      Rhymecrime::DynamoRuntime.client.describe_table(table_name: Rhymecrime::DataSource.table_name)
      { statusCode: 200, headers: { "Content-Type" => "text/plain" }, body: "ok" }
    rescue StandardError => e
      { statusCode: 503, headers: { "Content-Type" => "text/plain" }, body: e.message.to_s }
    end
  when ["POST", "/feedback"]
    handle_feedback(event)
  else
    { statusCode: 404, headers: { "Content-Type" => "text/plain" }, body: "not found" }
  end
end

# HTTP API v2 hands the request body in +event["body"]+, possibly base64-
# encoded (binary content types and a few size-driven cases). We always
# decode the flag rather than trusting Content-Type, since API Gateway is
# the authority on whether it base64'd before invoking us.
def handle_feedback(event)
  raw = event["body"].to_s
  raw = Base64.decode64(raw) if event["isBase64Encoded"]
  payload = raw.empty? ? {} : (JSON.parse(raw) rescue {})

  headers = (event["headers"] || {}).each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
  ip = event.dig("requestContext", "http", "sourceIp").to_s
  user_agent = headers["user-agent"].to_s

  ok = Rhymecrime::FeedbackStore.record!(
    cue: payload["cue"],
    related: payload["related"],
    verdict: payload["verdict"],
    ip: ip,
    user_agent: user_agent,
    session: payload["session"],
  )
  if ok
    { statusCode: 204, headers: { "Content-Type" => "application/json" }, body: "" }
  else
    { statusCode: 400, headers: { "Content-Type" => "application/json" }, body: { error: "invalid feedback payload" }.to_json }
  end
end
