# frozen_string_literal: true

require "spec_helper"
require "rhymecrime/route_inventory"
require "rhymecrime/paths"

RSpec.describe "route inventory (collisions with /:cue and /:cue/:related)" do
  let(:repo_root) { File.expand_path("..", __dir__) }
  let(:assets_dir) { File.join(repo_root, "assets") }

  it "freezes RESERVED_SINGLE_SEGMENTS expected by path-based word URLs (update when adding routes)" do
    expect(Rhymecrime::RouteInventory::RESERVED_SINGLE_SEGMENTS).to match_array([
      Rhymecrime::HttpPaths::HEALTH.delete_prefix("/"),
      Rhymecrime::HttpPaths::FEEDBACK.delete_prefix("/"),
      "similar",
    ])
  end

  describe "assets/" do
    def asset_files
      return [] unless File.directory?(assets_dir)

      Dir.chdir(assets_dir) do
        Dir.glob("**/*").filter_map do |rel|
          path = File.join(assets_dir, rel)
          path if File.file?(path)
        end
      end
    end

    it "has no extensionless filenames — Sinatra would serve them at /<basename> and collide with word paths" do
      extensionless = asset_files.reject { |p| File.basename(p).include?(".") }
      expect(extensionless).to eq([]),
                             "Add a dotted extension (e.g. .txt) or move out of assets/: #{extensionless.inspect}"
    end

    it "keeps lambda_handler ASSET_ROUTES in sync: every key basename contains a dot" do
      lambda_path = File.join(repo_root, "lambda_handler.rb")
      src = File.read(lambda_path, encoding: "UTF-8")
      paths = src.scan(%r{^\s*"(/[^"]+)"\s*=>}).flatten
      expect(paths).not_to be_empty

      bad = paths.reject { |p| File.basename(p.delete_prefix("/")).include?(".") }
      expect(bad).to eq([]),
                     "ASSET_ROUTES keys must include '.' so they cannot match dot-free /:word — #{bad.inspect}"
    end
  end
end
