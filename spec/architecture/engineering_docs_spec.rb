# frozen_string_literal: true

RSpec.describe "engineering documentation hierarchy" do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:engineering_root) { root.join("docs/engineering") }
  let(:sections) { %w[architecture conventions decisions operations maps pitfalls] }

  it "provides an index for every engineering knowledge category" do
    expect(engineering_root.join("README.md")).to exist
    expect(sections).to all(satisfy { |section| engineering_root.join(section, "README.md").exist? })
  end

  it "routes every category from the top-level index" do
    index = engineering_root.join("README.md").read

    sections.each do |section|
      expect(index).to include("(#{section}/README.md)")
    end
  end

  it "keeps local Markdown links in every engineering index resolvable" do
    indexes = [engineering_root.join("README.md")] + sections.map do |section|
      engineering_root.join(section, "README.md")
    end

    failures = indexes.flat_map do |index|
      markdown_links(index.read).filter_map do |target|
        next if target.start_with?("#") || target.match?(%r{\A[a-z][a-z0-9+.-]*:}i)

        path = target.split("#", 2).first
        "#{index.relative_path_from(root)} -> #{target}" unless index.dirname.join(path).exist?
      end
    end

    expect(failures).to be_empty, "Missing local Markdown targets:\n#{failures.join("\n")}"
  end

  def markdown_links(markdown)
    markdown.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
  end
end
