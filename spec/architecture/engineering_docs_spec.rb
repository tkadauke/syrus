# frozen_string_literal: true

RSpec.describe "engineering documentation hierarchy" do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:engineering_root) { root.join("docs/engineering") }
  let(:sections) { %w[architecture conventions decisions operations maps pitfalls] }
  let(:convention_guides) do
    %w[
      rails-and-services background-jobs-and-queues state-machines
      database-and-migrations testing frontend localization plugins
      prompts-and-tools cli-and-desktop documentation-policy deployment
    ]
  end

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

  it "routes every focused convention guide from the conventions index" do
    index = engineering_root.join("conventions/README.md").read

    convention_guides.each do |guide|
      expect(index).to include("(#{guide}.md)")
    end
  end

  it "keeps local Markdown links throughout engineering documentation resolvable" do
    documents = engineering_root.glob("**/*.md")

    failures = documents.flat_map do |document|
      markdown_links(document.read).filter_map do |target|
        next if target.start_with?("#") || target.match?(%r{\A[a-z][a-z0-9+.-]*:}i)

        path = target.split("#", 2).first
        "#{document.relative_path_from(root)} -> #{target}" unless document.dirname.join(path).exist?
      end
    end

    expect(failures).to be_empty, "Missing local Markdown targets:\n#{failures.join("\n")}"
  end

  it "keeps the legacy conventions reference as a concise compatibility pointer" do
    legacy = root.join(".claude/reference/conventions.md").read

    expect(legacy).to include("../../docs/engineering/conventions/README.md")
    expect(legacy.lines.length).to be <= 12
  end

  def markdown_links(markdown)
    markdown.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
  end
end
