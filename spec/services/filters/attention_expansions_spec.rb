require "rails_helper"

RSpec.describe Filters::Chips::Jobs::Attention do
  describe ".expansion_for" do
    it "returns a single chip for simple presets" do
      expect(described_class.expansion_for("pinned")).to eq(
        "field" => "pinned_by_me", "op" => "is_true", "value" => nil
      )
    end

    it "returns an AND tree for conjunctive presets like `stale`" do
      stale = described_class.expansion_for("stale")
      expect(stale).to have_key("and")
      expect(stale["and"]).to include(
        hash_including("field" => "state", "op" => "is", "value" => "open"),
        hash_including(
          "field" => "updated_at",
          "op" => "more_than_ago",
          "value" => { "n" => 7, "unit" => "days" }
        )
      )
    end

    it "wraps disjunctive presets like `blocked` in state=open AND (...)" do
      blocked = described_class.expansion_for("blocked")
      expect(blocked).to have_key("and")
      expect(blocked["and"]).to include(
        hash_including("field" => "state", "op" => "is", "value" => "open")
      )
      or_branch = blocked["and"].find { |c| c.key?("or") }
      expect(or_branch["or"]).to include(
        hash_including("field" => "has_blocked_deps", "op" => "is_true"),
        hash_including("field" => "pr_mergeable", "op" => "is_false")
      )
    end

    it "expands queued as queued jobs or jobs with a queued latest workflow" do
      queued = described_class.expansion_for("queued")
      expect(queued).to eq(
        "or" => [
          { "field" => "state", "op" => "is", "value" => "queued" },
          { "field" => "latest_workflow_state", "op" => "is", "value" => "queued" }
        ]
      )
    end

    it "expands inbox lossily — the OR group covers actionable primitives" do
      inbox = described_class.expansion_for("inbox")
      expect(inbox).to have_key("and")
      or_branch = inbox["and"].find { |child| child.key?("or") }
      expect(or_branch).not_to be_nil
      branches = or_branch["or"]
      fields = branches.filter_map { |c| c["field"] }
      # `state` appears twice (once for :failed, once for :implemented)
      # after the Phase 4 cleanup; that's the lossy OR-group expansion.
      expect(fields).to include(
        "validity", "state"
      )
      expect(branches).to include(
        "and" => [
          { "field" => "has_unread_feedback", "op" => "is_true", "value" => nil },
          { "field" => "state", "op" => "is_none_of", "value" => %w[triaging queued running landing] }
        ]
      )
      expect(branches).to include("field" => "has_landing_failure", "op" => "is_true", "value" => nil)
      expect(fields).not_to include("triaging_reason")
    end

    it "expands just_failed as failed state or landing failure" do
      just_failed = described_class.expansion_for("just_failed")

      expect(just_failed).to eq(
        "or" => [
          { "field" => "state", "op" => "is", "value" => "failed" },
          { "field" => "has_landing_failure", "op" => "is_true", "value" => nil }
        ]
      )
    end

    it "returns nil for unknown values" do
      expect(described_class.expansion_for("not_a_preset")).to be_nil
    end
  end

  describe ".expansions" do
    it "includes every defined expansion as parsed AST nodes" do
      expansions = described_class.expansions
      expect(expansions.keys).to match_array(%w[
        pinned in_progress queued inbox awaiting_approval just_failed
        stale blocked merged_this_week awaiting_epic needs_review
      ])
    end
  end

  describe "expansion round-trip through the AST" do
    it "every expansion parses cleanly into an Ast node" do
      described_class.expansions.each do |preset, expansion|
        # AND/OR/chip — all must be parseable. We wrap chips in an
        # AND so the parser sees the expected root shape.
        wrapped = expansion.key?("and") || expansion.key?("or") ? expansion : { "and" => [ expansion ] }
        expect { Filters::Ast.parse(wrapped) }.not_to raise_error, "preset #{preset} failed to parse"
      end
    end
  end
end
