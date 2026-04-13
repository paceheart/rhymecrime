# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "sinatra"
require "rhymecrime/frontend"

set :public_folder, File.expand_path("assets", __dir__)
set :bind, "0.0.0.0"

before do
  headers "Content-Type" => "text/html; charset=utf-8"
end

get "/" do
  build_rhymecrime_page(params["word1"], params["word2"])
end

get "/similar" do
  if Rhymecrime::DataSource.dynamodb?
    halt 501, "<!DOCTYPE html><html><body><p>Thematic similarity needs full in-memory lexicon; it is not available in DynamoDB mode.</p></body></html>"
  end
  build_similar_page(params["word1"], params["word2"])
end

get "/health" do
  content_type "text/plain"
  if Rhymecrime::DataSource.dynamodb?
    begin
      Rhymecrime::DynamoRuntime.client.describe_table(table_name: Rhymecrime::DataSource.table_name)
      "ok dynamodb"
    rescue StandardError => e
      halt 503, "dynamodb: #{e.message}"
    end
  else
    path = File.join(REPO_ROOT, "generated", "word_dict.txt")
    halt 503, "missing word_dict" unless File.exist?(path)

    "ok file"
  end
end
