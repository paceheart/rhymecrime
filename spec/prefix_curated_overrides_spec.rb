# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "spec_helper"
require "rhymecrime/build/prefix_curated_overrides"

RSpec.describe "prefix_curated_overrides" do
  before do
    @tmpdir = Dir.mktmpdir
    @csv = File.join(@tmpdir, "prefix.csv")
    stub_const("PREFIX_CURATED_CSV_PATH", @csv)
    reset_prefix_curated_overrides!
  end

  after do
    reset_prefix_curated_overrides!
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def write_csv(body)
    File.write(@csv, "prefix,base,verdict,note\n#{body}")
    reset_prefix_curated_overrides!
  end

  it "adds allow pairs to the gate" do
    write_csv("re,mind,allow,test override\n")
    gate = {}
    prefix_curated_overrides_apply!(gate)
    expect(gate["remind"]).to eq(%w[mind])
  end

  it "removes filter pairs from the gate" do
    write_csv("un,able,filter,test override\n")
    gate = { "unable" => %w[able] }
    prefix_curated_overrides_apply!(gate)
    expect(gate).not_to have_key("unable")
  end

  it "drops contradictory rows for the same prefix,base" do
    write_csv("re,mind,allow,a\nre,mind,filter,b\n")
    gate = {}
    prefix_curated_overrides_apply!(gate)
    expect(gate).not_to have_key("remind")
    expect(prefix_curated_overrides_stats[:contradictory]).to eq(1)
  end

  it "skips whatever verdict" do
    write_csv("re,mind,whatever,x\n")
    gate = {}
    prefix_curated_overrides_apply!(gate)
    expect(gate).to eq({})
    expect(prefix_curated_overrides_stats[:non_override_kind]).to eq(1)
  end

  it "honors RHYMECRIME_PREFIX_CSV_OVERRIDE=0" do
    write_csv("re,mind,allow,x\n")
    gate = {}
    old = ENV["RHYMECRIME_PREFIX_CSV_OVERRIDE"]
    ENV["RHYMECRIME_PREFIX_CSV_OVERRIDE"] = "0"
    reset_prefix_curated_overrides!
    prefix_curated_overrides_apply!(gate)
    expect(gate).to eq({})
  ensure
    ENV["RHYMECRIME_PREFIX_CSV_OVERRIDE"] = old
    reset_prefix_curated_overrides!
  end
end
