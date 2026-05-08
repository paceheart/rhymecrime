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

  it "does not load build/build_io.rb when requiring rhymecrime/crime" do
    assert_features_absent(
      "/rhymecrime/build/build_io.rb",
      'require "rhymecrime/crime"',
    )
  end

  it "does not load build/build_io.rb when requiring rhymecrime/related" do
    assert_features_absent(
      "/rhymecrime/build/build_io.rb",
      'require "rhymecrime/related"',
    )
  end
end
