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
  let(:focused_guides) do
    {
      architecture: %w[
        domain-model-and-work-engine workflow-execution workspace-lifecycle
        repository-content chat-and-sidecars plugins frontend
      ],
      operations: %w[deployment production-debugging workflow-recovery],
      maps: %w[
        core-domain-and-workflows repositories-and-integrations
        frontend-and-plugins tests queues-and-databases
      ],
      pitfalls: %w[
        workspace-and-execution queues-databases-and-polling
        documentation-and-plugin-boundaries
      ]
    }
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

  it "routes every focused architecture, operations, map, and pitfall guide" do
    focused_guides.each do |section, guides|
      index = engineering_root.join(section.to_s, "README.md").read

      guides.each do |guide|
        expect(engineering_root.join(section.to_s, "#{guide}.md")).to exist
        expect(index).to include("(#{guide}.md)")
      end
    end
  end

  it "keeps ARCHITECTURE.md as the system overview and focused-doc router" do
    overview = root.join("ARCHITECTURE.md").read

    expect(overview).to include("canonical system-wide overview")
    focused_guides.keys.each do |section|
      expect(overview).to include("docs/engineering/#{section}/")
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

  it "keeps superseded deep references as concise compatibility pointers" do
    pointers = {
      "architecture-details.md" => "../../docs/engineering/architecture/README.md",
      "deployed-operations.md" => "../../docs/engineering/operations/README.md",
      "gotchas-and-key-files.md" => "../../docs/engineering/maps/README.md"
    }

    pointers.each do |filename, target|
      legacy = root.join(".claude/reference", filename).read
      expect(legacy).to include(target)
      expect(legacy.lines.length).to be <= 12
    end
  end

  def markdown_links(markdown)
    markdown.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
  end
end
