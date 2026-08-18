require "rails_helper"

# The repo-local `.syrus/skills/backport-hotfixes/SKILL.md` skill (EPIC-235)
# that reconciles `main` back into `development` for periodic ScheduledTask
# invocation (JOB-3172). Like `promote` (JOB-3152/spec/skills/promote_spec.rb),
# this is plain git-tracked markdown with no Ruby class behind it —
# Skills::SkillMarkdown is what turns it into a Skills::Definition. These
# specs parse and render the *actual* checked-in file, so a future edit that
# breaks its frontmatter or param substitution fails here instead of
# silently shipping.
RSpec.describe ".syrus/skills/backport-hotfixes/SKILL.md" do
  let(:path) { Rails.root.join(".syrus/skills/backport-hotfixes/SKILL.md") }
  let(:contents) { File.read(path) }
  let(:definition) { Skills::SkillMarkdown.parse(contents, name: "backport-hotfixes") }

  it "exists and parses as a valid skill definition" do
    expect(File).to exist(path)
    expect(definition).to be_a(Skills::Definition)
    expect(definition.name).to eq("backport-hotfixes")
    expect(definition.description).to be_present
  end

  describe "parameter schema" do
    it "declares exactly the parameters from the issue spec, none required" do
      by_key = definition.parameters.index_by(&:key)

      expect(by_key.keys).to contain_exactly("source_branch", "target_branch", "max_commits")
      expect(by_key.values).to all(have_attributes(required: false))
    end

    it "defaults source_branch to main and target_branch to development" do
      by_key = definition.parameters.index_by(&:key)

      expect(by_key["source_branch"].type).to eq("string")
      expect(by_key["source_branch"].default).to eq("main")

      expect(by_key["target_branch"].type).to eq("string")
      expect(by_key["target_branch"].default).to eq("development")
    end

    it "declares max_commits as an optional integer cap with no numeric default" do
      field = definition.parameters.index_by(&:key)["max_commits"]

      expect(field.type).to eq("integer")
      expect(field.required).to eq(false)
    end

    it "accepts an empty args hash — every parameter has a usable default" do
      expect { Skills::ParameterSchema.validate!(definition.parameters, {}) }.not_to raise_error
    end

    it "accepts a submitted numeric max_commits" do
      expect { Skills::ParameterSchema.validate!(definition.parameters, { "max_commits" => "5" }) }.not_to raise_error
    end

    it "rejects a non-numeric max_commits" do
      expect { Skills::ParameterSchema.validate!(definition.parameters, { "max_commits" => "soon" }) }
        .to raise_error(Skills::ParameterSchema::ValidationError, /max_commits/)
    end
  end

  describe "rendering" do
    it "renders with defaults when no args are supplied, leaving no unresolved placeholders" do
      rendered = Skills::Renderer.render(definition, {})

      expect(rendered).to include("source_branch=`main`")
      expect(rendered).to include("target_branch=`development`")
      expect(rendered).to include("max_commits=``")
      expect(rendered).to include("git log --reverse --format=%H origin/development..origin/main")
      expect(rendered).not_to match(/\{\{\s*\w+\s*\}\}/)
    end

    it "renders with every param overridden" do
      rendered = Skills::Renderer.render(definition, {
        "source_branch" => "main",
        "target_branch" => "release/2026",
        "max_commits" => "3"
      })

      expect(rendered).to include("source_branch=`main`")
      expect(rendered).to include("target_branch=`release/2026`")
      expect(rendered).to include("max_commits=`3`")
      expect(rendered).to include("git log --reverse --format=%H origin/release/2026..origin/main")
      expect(rendered).not_to include("`development`")
      expect(rendered).not_to match(/\{\{\s*\w+\s*\}\}/)
    end
  end

  describe "content coverage of the issue's required behaviors" do
    # Normalize whitespace so hard-wrapped markdown prose doesn't break a
    # phrase match across a line break.
    let(:flat) { definition.instructions.gsub(/\s+/, " ") }

    it "instructs computing the commit range with git log development..main semantics" do
      expect(flat).to match(/git log --reverse --format=%H origin\/\{\{target_branch\}\}\.\.origin\/\{\{source_branch\}\}/)
    end

    it "instructs exiting cleanly with no commits when the branches are already in sync" do
      expect(flat).to match(/list is empty/i)
      expect(flat).to match(/do not create any commits/i)
      expect(flat).to match(/no-op/i)
    end

    it "instructs cherry-picking in commit order rather than merging" do
      expect(flat).to match(/cherry-pick/i)
      expect(flat).to match(/never `git merge`/i)
      expect(flat).to match(/in order, oldest first/i)
    end

    it "instructs running this repo's own test/lint commands before treating the backport as done" do
      expect(flat).to match(/\.syrus\.yml/)
      expect(flat).to match(/before treating the backport as done/i)
    end

    it "instructs stopping and reporting the conflicting commit without attempting automatic resolution" do
      expect(flat).to match(/conflict/i)
      expect(flat).to match(/git cherry-pick --abort/)
      expect(flat).to match(/do not attempt automatic conflict resolution/i)
      expect(flat).to match(/which commit conflicted/i)
    end

    it "instructs bounding a run with max_commits and reporting any remaining backlog" do
      expect(flat).to match(/max_commits is set/i)
      expect(flat).to match(/backlog/i)
    end

    it "describes opening a PR against the target branch and having no push credentials" do
      expect(flat).to match(/pull request against `\{\{target_branch\}\}`/)
      expect(flat).to match(/do not have.*push credentials/i)
    end
  end
end
