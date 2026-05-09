# frozen_string_literal: true

require "spec_helper"
require "rhymecrime/paths"

RSpec.describe "Rhymecrime::HttpPaths (parity with SAM + browser assets)" do
  let(:repo_root) { File.expand_path("..", __dir__) }

  it "template.yaml wires ApiHealth / ApiFeedback to the same paths as HttpPaths" do
    yaml_text = File.read(File.join(repo_root, "template.yaml"), encoding: "UTF-8")
    expect(yaml_text).to match(/ApiHealth:[\s\S]*?\n\s+Path:\s+#{Regexp.escape(Rhymecrime::HttpPaths::HEALTH)}\s*\n\s+Method:\s+GET\b/)
    expect(yaml_text).to match(/ApiFeedback:[\s\S]*?\n\s+Path:\s+#{Regexp.escape(Rhymecrime::HttpPaths::FEEDBACK)}\s*\n\s+Method:\s+POST\b/)
  end

  it "assets/feedback.js posts to HttpPaths::FEEDBACK" do
    js = File.read(File.join(repo_root, "assets", "feedback.js"), encoding: "UTF-8")
    expect(js).to match(/fetch\s*\(\s*"#{Regexp.escape(Rhymecrime::HttpPaths::FEEDBACK)}"/)
  end

  it "lambda_handler.rb branches on HttpPaths::HEALTH and HttpPaths::FEEDBACK" do
    src = File.read(File.join(repo_root, "lambda_handler.rb"), encoding: "UTF-8")
    expect(src).to include("Rhymecrime::HttpPaths::HEALTH")
    expect(src).to include("Rhymecrime::HttpPaths::FEEDBACK")
    expect(src).to include("handle_feedback(event)")
  end

  it "app.rb registers Sinatra routes via HttpPaths" do
    src = File.read(File.join(repo_root, "app.rb"), encoding: "UTF-8")
    expect(src).to include("post Rhymecrime::HttpPaths::FEEDBACK")
    expect(src).to include("get Rhymecrime::HttpPaths::HEALTH")
  end

  it "assets/private/header.html wires the search form for slash URLs (id + script)" do
    html = File.read(File.join(repo_root, "assets", "private", "header.html"), encoding: "UTF-8")
    expect(html).to include('id="rhymecrime-search"')
    expect(html).to include("encodeURIComponent")
  end

  it "print_html_header injects data-rc-path-search only for RhymeCrime pages" do
    src = File.read(File.join(repo_root, "lib/rhymecrime/frontend/frontend.rb"), encoding: "UTF-8")
    expect(src).to include('data-rc-path-search="1"')
  end
end
