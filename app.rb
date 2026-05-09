# frozen_string_literal: true

# Mirror lambda_handler.rb: under a minimal locale Rack may leave
# Encoding.default_external as US-ASCII / ASCII-8BIT, which breaks
# multibyte paths the same way the Lambda comment describes for the AWS SDK.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "json"
require "sinatra"
require "rhymecrime/paths"
require "rhymecrime/frontend/frontend"
require "rhymecrime/store/feedback_store"
require "rhymecrime/about_page"

set :public_folder, File.expand_path("assets", __dir__)
set :bind, "0.0.0.0"

helpers do
  def rhymecrime_http_page(word1, word2)
    debug = params["debug"] == "1"
    begin
      build_rhymecrime_page(word1, word2, debug: debug)
    rescue StandardError => e
      raise unless debug

      content_type "text/plain"
      status 500
      "#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
    end
  end
end

before do
  headers "Content-Type" => "text/html; charset=utf-8"
end

get "/robots.txt" do
  content_type "text/plain; charset=utf-8"
  File.read(File.join(settings.public_folder, "robots.txt"), encoding: "UTF-8")
end

get "/" do
  # Lookups are path-only (/<cue>, /<cue>/<related>); word1/word2 query params are ignored.
  rhymecrime_http_page("", "")
end

get "/about.html" do
  Rhymecrime::AboutPage.html
end

get "/similar" do
  if Rhymecrime::DataSource.dynamodb?
    halt 501, "<!DOCTYPE html><html><body><p>Thematic similarity needs full in-memory lexicon; it is not available in DynamoDB mode.</p></body></html>"
  end
  build_similar_page(params["word1"], params["word2"])
end

post Rhymecrime::HttpPaths::FEEDBACK do
  content_type :json
  body = request.body.read
  payload = body.empty? ? {} : (JSON.parse(body) rescue {})
  ok = Rhymecrime::FeedbackStore.record!(
    cue: payload["cue"],
    related: payload["related"],
    verdict: payload["verdict"],
    ip: request.ip,
    user_agent: request.user_agent,
    session: payload["session"],
  )
  status(ok ? 204 : 400)
  ok ? "" : { error: "invalid feedback payload" }.to_json
end

get Rhymecrime::HttpPaths::HEALTH do
  content_type "text/plain"
  if Rhymecrime::DataSource.dynamodb?
    begin
      Rhymecrime::DynamoRuntime.instance.client.describe_table(table_name: Rhymecrime::DataSource.table_name)
      "ok dynamodb"
    rescue StandardError => e
      halt 503, "dynamodb: #{e.message}"
    end
  else
    path = File.join(REPO_ROOT, "generated", "current", "word_dict.txt")
    halt 503, "missing word_dict" unless File.exist?(path)

    "ok file"
  end
end

get %r{/([^/.]+)/([^/.]+)} do
  parsed = Rhymecrime::LookupPaths.parse_path(request.path_info)
  pass if parsed.nil?

  rhymecrime_http_page(*parsed)
end

get %r{/([^/.]+)} do
  parsed = Rhymecrime::LookupPaths.parse_path(request.path_info)
  pass if parsed.nil?

  rhymecrime_http_page(*parsed)
end
