# frozen_string_literal: true

RSpec.describe "Runtime require graph" do
  def assert_features_absent(feature_suffix, code)
    repo_root = File.expand_path("..", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{repo_root.inspect} + "/lib")
      #{code}
      bad = $LOADED_FEATURES.select { |f| f.end_with?(#{feature_suffix.inspect}) }
      warn("unexpected: \#{bad.inspect}") unless bad.empty?
      exit(bad.empty? ? 0 : 1)
    RUBY
    expect(system(RbConfig.ruby, "-e", script)).to eq(true)
  end

  it "does not load build/build_io.rb when requiring rhymecrime/frontend/query" do
    assert_features_absent(
      "/rhymecrime/build/build_io.rb",
      'require "rhymecrime/frontend/query"',
    )
  end

  it "does not load any lib/rhymecrime/build/*.rb when booting like Lambda (query + feedback_store)" do
    repo_root = File.expand_path("..", __dir__)
    script = <<~RUBY
      ENV["RHYMECRIME_DATA_SOURCE"] = "dynamodb"
      ENV["TABLE_NAME"] ||= "rhymecrime"
      $LOAD_PATH.unshift(#{repo_root.inspect} + "/lib")
      before = $LOADED_FEATURES.dup
      require "rhymecrime/frontend/query"
      require "rhymecrime/store/feedback_store"
      after = $LOADED_FEATURES - before
      bad = after.select { |f| f.end_with?(".rb") && f.include?("/rhymecrime/build/") }
      warn("unexpected build requires: \#{bad.inspect}") unless bad.empty?
      exit(bad.empty? ? 0 : 1)
    RUBY
    expect(system(RbConfig.ruby, "-E", "UTF-8:UTF-8", "-e", script)).to eq(true)
  end

  it "does not load build/build_io.rb when requiring rhymecrime/related" do
    assert_features_absent(
      "/rhymecrime/build/build_io.rb",
      'require "rhymecrime/related"',
    )
  end
end
