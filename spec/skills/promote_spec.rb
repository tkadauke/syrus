require "rails_helper"

# The repo-local `.syrus/skills/promote/SKILL.md` skill (EPIC-235) that
# merges `development` onto `main` on operator demand. Unlike the built-in
# skills under app/services/skills/, this one is plain git-tracked markdown
# with no Ruby class behind it — Skills::SkillMarkdown is what turns it into
# a Skills::Definition. These specs parse and render the *actual* checked-in
# file, so a future edit to the SKILL.md that breaks its frontmatter or
# param substitution fails here instead of silently shipping.
RSpec.describe ".syrus/skills/promote/SKILL.md" do
  let(:path) { Rails.root.join(".syrus/skills/promote/SKILL.md") }
  let(:contents) { File.read(path) }
  let(:definition) { Skills::SkillMarkdown.parse(contents, name: "promote") }

  it "exists and parses as a valid skill definition" do
    expect(File).to exist(path)
    expect(definition).to be_a(Skills::Definition)
    expect(definition.name).to eq("promote")
    expect(definition.description).to be_present
  end

  describe "parameter schema" do
    it "declares exactly the parameters from the issue spec, none required" do
      by_key = definition.parameters.index_by(&:key)

      expect(by_key.keys).to contain_exactly("source_branch", "target_branch", "strategy", "open_pr")
      expect(by_key.values).to all(have_attributes(required: false))
    end

    it "defaults source_branch to development and target_branch to main" do
      by_key = definition.parameters.index_by(&:key)

      expect(by_key["source_branch"].type).to eq("string")
      expect(by_key["source_branch"].default).to eq("development")

      expect(by_key["target_branch"].type).to eq("string")
      expect(by_key["target_branch"].default).to eq("main")
    end

    it "restricts strategy to merge_commit/fast_forward, defaulting to merge_commit" do
      field = definition.parameters.index_by(&:key)["strategy"]

      expect(field.type).to eq("select")
      expect(field.options).to eq(%w[merge_commit fast_forward])
      expect(field.default).to eq("merge_commit")
    end

    it "defaults open_pr to true as a boolean parameter" do
      field = definition.parameters.index_by(&:key)["open_pr"]

      expect(field.type).to eq("boolean")
      expect(field.default).to eq(true)
    end

    it "accepts an empty args hash — every parameter has a usable default" do
      expect { Skills::ParameterSchema.validate!(definition.parameters, {}) }.not_to raise_error
    end
  end

  describe "rendering" do
    it "renders with defaults when no args are supplied" do
      rendered = Skills::Renderer.render(definition, {})

      expect(rendered).to include("source_branch=`development`")
      expect(rendered).to include("target_branch=`main`")
      expect(rendered).to include("strategy=`merge_commit`")
      expect(rendered).to include("open_pr=`true`")
      expect(rendered).to include("promoting `development` onto `main`")
      expect(rendered).to include("git merge --no-ff origin/development")
      expect(rendered).to include("git merge --ff-only origin/development")
      expect(rendered).not_to match(/\{\{\s*\w+\s*\}\}/)
    end

    it "renders with every param overridden" do
      rendered = Skills::Renderer.render(definition, {
        "source_branch" => "feature/big-thing",
        "target_branch" => "stable",
        "strategy" => "fast_forward",
        "open_pr" => false
      })

      expect(rendered).to include("source_branch=`feature/big-thing`")
      expect(rendered).to include("target_branch=`stable`")
      expect(rendered).to include("strategy=`fast_forward`")
      expect(rendered).to include("open_pr=`false`")
      expect(rendered).to include("promoting `feature/big-thing` onto `stable`")
      expect(rendered).to include("git merge --ff-only origin/feature/big-thing")
      expect(rendered).not_to include("`development`")
      expect(rendered).not_to include("onto `main`")
      expect(rendered).not_to match(/\{\{\s*\w+\s*\}\}/)
    end

    it "substitutes source_branch into both merge command variants" do
      rendered = Skills::Renderer.render(definition, { "source_branch" => "trunk" })

      expect(rendered).to include("git merge --no-ff origin/trunk")
      expect(rendered).to include("git merge --ff-only origin/trunk")
    end
  end

  describe "content coverage of the issue's required behaviors" do
    # Normalize whitespace so hard-wrapped markdown prose doesn't break a
    # phrase match across a line break.
    let(:flat) { definition.instructions.gsub(/\s+/, " ") }

    it "instructs running this repo's own test/lint commands before treating the merge as successful" do
      expect(flat).to match(/\.syrus\.yml/)
      expect(flat).to match(/before you consider the merge/i)
    end

    it "instructs stopping and reporting clearly on conflict, without force-pushing or leaving the target branch broken" do
      expect(flat).to match(/conflict/i)
      expect(flat).to match(/git merge --abort/)
      expect(flat).to match(/force-push/i)
      expect(flat).to match(/explain clearly/i)
    end

    it "describes opening a PR against the target branch by default" do
      expect(flat).to match(/pull request against `\{\{target_branch\}\}`/)
    end

    it "acknowledges the agent has no push credentials in this workspace" do
      expect(flat).to match(/do not have.*push credentials/i)
    end
  end
end
