# frozen_string_literal: true

RSpec.describe "CLAUDE.md startup context size" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:claude_md_path) { File.join(root, "CLAUDE.md") }

  it "stays below Muse's workspace-rules startup context limit with headroom" do
    expect(File.size(claude_md_path)).to be < 35 * 1024
  end

  it "keeps AGENTS.md resolving to the same slim guide" do
    agents_path = File.join(root, "AGENTS.md")

    expect(File.symlink?(agents_path)).to be(true)
    expect(File.realpath(agents_path)).to eq(File.realpath(claude_md_path))
  end

  it "references only existing local markdown targets" do
    links = File.read(claude_md_path).scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
    local_links = links.reject { |link| link.match?(%r{\A[a-z][a-z0-9+.-]*:}i) || link.start_with?("#") }

    expect(local_links).not_to be_empty
    expect(local_links).to all(satisfy do |link|
      path = link.split("#", 2).first
      File.exist?(File.expand_path(path, root))
    end)
  end
end
