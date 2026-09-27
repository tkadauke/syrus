# frozen_string_literal: true

require "spec_helper"

RSpec.describe "CLAUDE.md progressive disclosure" do
  MAX_BYTES = 35_000

  def claude_path
    File.expand_path("../../CLAUDE.md", __dir__)
  end

  it "keeps the startup rules file below Muse's context limit with headroom" do
    expect(File.size(claude_path)).to be <= MAX_BYTES
  end

  it "keeps AGENTS.md resolving to the same slim guide" do
    path = File.expand_path("../../AGENTS.md", __dir__)

    expect(File.symlink?(path)).to be(true)
    expect(File.readlink(path)).to eq("CLAUDE.md")
  end

  it "only links to existing local references" do
    root = File.expand_path("../..", __dir__)
    links = File.read(claude_path).scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
    local_links = links.reject { |href| href.match?(%r{\A(?:https?:|mailto:|#)}) }

    missing = local_links.filter_map do |href|
      path = href.delete_prefix("./").split("#", 2).first
      next if path.empty?

      target = File.expand_path(path, root)
      href unless File.exist?(target)
    end

    expect(missing).to be_empty
  end
end
