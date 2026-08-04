require "rails_helper"

RSpec.describe Step::Kind do
  it "is the canonical source for Step validation values and handler registry" do
    expect(Step::KINDS).to eq(described_class.values)
    expect(Steps::REGISTRY).to eq(described_class.registry)
  end

  it "has a label, style, and loadable handler for every step kind" do
    described_class.values.each do |kind|
      entry = described_class.fetch(kind)

      expect(entry.label).to be_present, "expected #{kind} to have a label"
      expect(entry.style).to be_present, "expected #{kind} to have a style"
      expect(entry.handler_class).to be < Steps::Base
    end
  end

  it "gives newer non-agentic steps deliberate product copy" do
    expect(described_class.label_for("apply_suggestions")).to eq("Apply suggestions")
    expect(described_class.style_for("apply_suggestions")).to eq("bg-lime-100 text-lime-700")
    expect(described_class.label_for("landing_fix")).to eq("Final fix")
    expect(described_class.style_for("landing_fix")).to eq("bg-blue-100 text-blue-700")
    expect(described_class.label_for("grader_fanout")).to eq("Plan graders")
    expect(described_class.style_for("grader_fanout")).to eq("bg-violet-100 text-violet-700")
    expect(described_class.label_for("mergeability_preflight")).to eq("Mergeability preflight")
    expect(described_class.style_for("mergeability_preflight")).to eq("bg-sky-100 text-sky-700")
    expect(described_class.label_for("auto_merge")).to eq("Auto-merge")
    expect(described_class.style_for("auto_merge")).to eq("bg-green-100 text-green-700")
  end

  describe "required_mcp_tools" do
    it "returns submit_summary for summarize and summarize_amend" do
      expect(described_class.fetch("summarize").required_mcp_tools).to eq(%w[submit_summary])
      expect(described_class.fetch("summarize_amend").required_mcp_tools).to eq(%w[submit_summary])
    end

    it "returns submit_test_plan for test_plan" do
      expect(described_class.fetch("test_plan").required_mcp_tools).to eq(%w[submit_test_plan])
    end

    it "returns submit_job_metadata for refresh_job_metadata" do
      expect(described_class.fetch("refresh_job_metadata").required_mcp_tools).to eq(%w[submit_job_metadata])
    end

    it "returns submit_adversarial_review for adversarial_review" do
      expect(described_class.fetch("adversarial_review").required_mcp_tools).to eq(%w[submit_adversarial_review])
    end

    it "returns empty array for non-submission steps" do
      %w[implement respond prepare pr_open push grader grader_collect].each do |kind|
        expect(described_class.fetch(kind).required_mcp_tools).to eq([]),
          "expected #{kind} to have no required_mcp_tools"
      end
    end
  end

  describe "fail_policy" do
    it "returns :advance for grader (advances past failure to let siblings run)" do
      expect(described_class.fetch("grader").fail_policy).to eq(:advance)
    end

    it "returns :loop_iteration for grader_collect and grade (drives retry loop)" do
      expect(described_class.fetch("grader_collect").fail_policy).to eq(:loop_iteration)
      expect(described_class.fetch("grade").fail_policy).to eq(:loop_iteration)
    end

    it "returns :default for all other step kinds" do
      %w[prepare implement respond summarize pr_open push auto_merge landing_fix].each do |kind|
        expect(described_class.fetch(kind).fail_policy).to eq(:default),
          "expected #{kind} to have :default fail_policy"
      end
    end
  end

  describe "reconcile_strategy" do
    it "returns :pr_open for pr_open" do
      expect(described_class.fetch("pr_open").reconcile_strategy).to eq(:pr_open)
    end

    it "returns :auto_merge for auto_merge" do
      expect(described_class.fetch("auto_merge").reconcile_strategy).to eq(:auto_merge)
    end

    it "returns :merge_train_land for both merge_train_land and merge_train_land_after_rebase" do
      expect(described_class.fetch("merge_train_land").reconcile_strategy).to eq(:merge_train_land)
      expect(described_class.fetch("merge_train_land_after_rebase").reconcile_strategy).to eq(:merge_train_land)
    end

    it "returns nil for non-reconcilable steps" do
      %w[prepare implement respond summarize push grader grader_collect].each do |kind|
        expect(described_class.fetch(kind).reconcile_strategy).to be_nil,
          "expected #{kind} to have no reconcile_strategy"
      end
    end
  end

  describe "skip_if_artifact" do
    it "returns 'test_plan' for test_plan (skipped when artifact already present)" do
      expect(described_class.fetch("test_plan").skip_if_artifact).to eq("test_plan")
    end

    it "returns nil for all other step kinds" do
      %w[prepare implement summarize pr_open push grader grader_collect].each do |kind|
        expect(described_class.fetch(kind).skip_if_artifact).to be_nil,
          "expected #{kind} to have no skip_if_artifact"
      end
    end
  end

  describe "triggers_auto_approval" do
    it "returns true for grade and grader_collect (the terminal grader steps)" do
      expect(described_class.fetch("grade").triggers_auto_approval).to be(true)
      expect(described_class.fetch("grader_collect").triggers_auto_approval).to be(true)
    end

    it "returns false for individual grader steps (only the collector fires auto-approval)" do
      expect(described_class.fetch("grader").triggers_auto_approval).to be(false)
    end

    it "returns false for all non-grader steps" do
      %w[prepare implement respond summarize pr_open push auto_merge].each do |kind|
        expect(described_class.fetch(kind).triggers_auto_approval).to be(false),
          "expected #{kind} to not trigger auto-approval"
      end
    end
  end

  describe "resource profile metadata" do
    it "expands fanout steps to the dynamic grader profiles they create" do
      expect(described_class.fetch("grader_fanout").resource_profile_keys_for).to eq([
        [ "grader_fanout", "" ],
        [ "grader", nil ]
      ])
      expect(described_class.fetch("preflight_grader_fanout").resource_profile_keys_for).to eq([
        [ "preflight_grader_fanout", "" ],
        [ "preflight_grader", nil ]
      ])
    end

    it "uses the grader name from step details for individual grader profiles" do
      step = Step.new(kind: "grader", details: { "name" => "rspec" })

      expect(described_class.fetch("grader").resource_profile_keys_for(step)).to eq([
        [ "grader", "rspec" ]
      ])
    end
  end

  describe "repair_semantics" do
    it "marks deterministic idempotent steps as safe in-place retry candidates" do
      %w[prepare grader grader_collect grade coverage_analyze preflight_grader].each do |kind|
        expect(described_class.fetch(kind)).to be_deterministic_idempotent_repair,
          "expected #{kind} to be deterministic/idempotent for repair planning"
      end
    end

    it "marks git publication and landing steps as publication repairs" do
      %w[pr_open push push_after_rebase force_push auto_merge merge_train_land].each do |kind|
        expect(described_class.fetch(kind)).to be_publication_repair,
          "expected #{kind} to require publication-aware repair planning"
      end
    end

    it "marks merge train build for the rebuild path" do
      expect(described_class.fetch("merge_train_build")).to be_rebuild_repair
    end
  end
end
