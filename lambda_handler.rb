# frozen_string_literal: true

# AWS Lambda's Ruby runtime ships with +LANG+ unset (or set to +C+), which
# leaves +Encoding.default_external+ at +US-ASCII+. Net::HTTP then tags
# response bodies as US-ASCII; when the AWS SDK's JSON parser hits the first
# multibyte UTF-8 sequence in a DynamoDB response (a +\xC3+ from any cue or
# related word like +café+, +naïve+, +résumé+, or any of the Spanish/French
# loanwords in our dict), +String#encode("utf-8")+ raises
# +Encoding::InvalidByteSequenceError+ and the request 500s.
#
# Forcing UTF-8 here — before any +require+ that triggers SDK or Net::HTTP
# loading — makes every subsequent +File.read+, +Net::HTTP.get+, and
# +JSON.parse+ in this process tag strings as UTF-8 by default. Belt-and-
# suspenders: +template.yaml+ also pins +LANG=en_US.UTF-8+ on the function;
# this line keeps things sane even if that env var ever drifts.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

$LOAD_PATH.unshift(File.join(__dir__, "lib"))

ENV["RHYMECRIME_DATA_SOURCE"] = "dynamodb"
ENV["RHYMECRIME_TABLE_NAME"] ||= ENV.fetch("TABLE_NAME", "rhymecrime")

require "base64"
require "json"
require "rhymecrime/frontend"
require "rhymecrime/feedback_store"

# Static asset table. assets/header.html references these as root-relative
# URLs (+/crimestyle.css+, etc.), so the Lambda has to answer for them too —
# API Gateway HTTP API has no static-file shortcut and there's no CloudFront
# in front of us. Reading at module load (rather than per-request) means a
# warm container serves each asset out of memory; a missing file blows up
# init loudly instead of silent-404'ing on every page render.
#
# When you add a new +<link rel=stylesheet>+ or +<script src>+ in
# +assets/header.html+ (or anywhere else served from /), mirror an entry
# below or the deployed page silently degrades to default browser styling.
ASSET_ROUTES = {
  "/crimestyle.css"      => ["text/css; charset=utf-8",               File.read(File.join(__dir__, "assets", "crimestyle.css"),      encoding: "UTF-8")],
  "/crimestyle-wide.css" => ["text/css; charset=utf-8",               File.read(File.join(__dir__, "assets", "crimestyle-wide.css"), encoding: "UTF-8")],
  "/feedback.js"         => ["application/javascript; charset=utf-8", File.read(File.join(__dir__, "assets", "feedback.js"),         encoding: "UTF-8")],
}.freeze

def asset_response(path)
  content_type, body = ASSET_ROUTES.fetch(path)
  {
    statusCode: 200,
    headers: {
      "Content-Type"  => content_type,
      # 5-minute cache: short enough that a redeploy of CSS/JS rolls out
      # fast, long enough to amortize Lambda invocations across a session.
      # Bump to 1y +immutable+ once we hash filenames for cache-busting.
      "Cache-Control" => "public, max-age=300",
    },
    body: body,
  }
end

def handler(event:, context:)
  # Lexicon and rime cohort are loaded once from +word_dict.msgpack+ /
  # +rime_dict.msgpack+ at process boot and stay resident across warm-
  # container invocations (immutable per data deploy — see +bin/stage-
  # lambda+). +DynamoRuntime+ no longer holds any per-session state, so the
  # only cache that needs invalidating per request is +RelatedWords+'s
  # in-process result memo (cue-keyed, would otherwise leak across users).
  RelatedWords.reset_caches! if defined?(RelatedWords)

  path = event["rawPath"] || event.dig("requestContext", "http", "path") || "/"
  method = event.dig("requestContext", "http", "method") || "GET"
  params = event["queryStringParameters"] || {}
  word1 = params["word1"].to_s
  word2 = params["word2"].to_s
  # +?debug=1+ is the catch-all dev affordance: drives the pruning visualizer
  # AND set_related per-word coloring. Mirrored in +app.rb+ for local dev.
  debug = params["debug"].to_s == "1"

  case [method, path]
  when ["GET", "/"]
    body = build_rhymecrime_page(word1, word2, debug: debug)
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
    if method == "GET" && ASSET_ROUTES.key?(path)
      asset_response(path)
    else
      { statusCode: 404, headers: { "Content-Type" => "text/plain" }, body: "not found" }
    end
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
