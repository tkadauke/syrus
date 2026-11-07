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
        scheduling-and-polling runtime-services-and-ui repository-content
        chat-and-sidecars plugins frontend system-reference runtime-reference
      ],
      operations: %w[deployment production-debugging workflow-recovery deployed-reference],
      maps: %w[
        core-domain-and-workflows repositories-and-integrations
        frontend-and-plugins tests queues-and-databases key-files-reference
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

  it "keeps local Markdown links and anchors throughout engineering documentation resolvable" do
    documents = engineering_root.glob("**/*.md") +
      [root.join("ARCHITECTURE.md"), root.join("SECURITY.md")]

    failures = documents.flat_map do |document|
      markdown_links(document.read).filter_map do |target|
        next if target.match?(%r{\A[a-z][a-z0-9+.-]*:}i)

        path, fragment = target.split("#", 2)
        destination = path.empty? ? document : document.dirname.join(path)
        if !destination.exist?
          "#{document.relative_path_from(root)} -> #{target} (missing target)"
        elsif fragment && destination.extname == ".md" &&
            !markdown_anchors(destination.read).include?(fragment)
          "#{document.relative_path_from(root)} -> #{target} (missing anchor)"
        end
      end
    end

    expect(failures).to be_empty, "Missing local Markdown targets:\n#{failures.join("\n")}"
  end

  it "preserves the routed architecture topics that previously lived in deep references" do
    topics = {
      "architecture/domain-model-and-work-engine.md" => %w[WorkIntent WorkUnit access security],
      "architecture/workflow-execution.md" => %w[pipeline feedback rebase landing],
      "architecture/scheduling-and-polling.md" => %w[PollRepositoryJob scheduled external stale],
      "architecture/runtime-services-and-ui.md" => %w[Terminal preview live Browser],
      "architecture/chat-and-sidecars.md" => %w[chat MCP sidecar external],
      "operations/deployment.md" => %w[deploy migration worker rollout],
      "operations/production-debugging.md" => %w[kubectl queue logs worker],
      "operations/workflow-recovery.md" => %w[retry resume Reconciler workspace]
    }

    topics.each do |relative_path, expected_topics|
      content = engineering_root.join(relative_path).read
      expected_topics.each { |topic| expect(content).to include(topic) }
    end
  end

  it "retains the complete deep-reference inventories behind hierarchy links" do
    inventories = {
      "architecture/system-reference.md" => [2_500, "## Per-poller flow", "## Deployment topology"],
      "architecture/runtime-reference.md" => [700, "### Trigger kinds", "### Live UI"],
      "operations/deployed-reference.md" => [200, "## Debugging deployed environments via kubectl", "## Deploy target"],
      "maps/key-files-reference.md" => [100, "## Things that bit us", "## Key files at a glance"]
    }

    inventories.each do |relative_path, (minimum_lines, *headings)|
      content = engineering_root.join(relative_path).read
      expect(content.lines.length).to be >= minimum_lines
      headings.each { |heading| expect(content).to include(heading) }
    end
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

  def markdown_anchors(markdown)
    counts = Hash.new(0)

    markdown.lines.filter_map do |line|
      heading = line[/\A\s{0,3}\#{1,6}\s+(.+?)\s*#*\s*\z/, 1]
      next unless heading

      slug = heading
        .gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1")
        .gsub(/<[^>]+>/, "")
        .delete("`*_~")
        .downcase
        .gsub(/[^\p{Alnum}\p{Space}-]/, "")
        .strip
        .gsub(/\s+/, "-")
      duplicate = counts[slug]
      counts[slug] += 1
      duplicate.zero? ? slug : "#{slug}-#{duplicate}"
    end
  end
end
