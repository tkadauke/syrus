require "rails_helper"

RSpec.describe Filters::Schema do
  describe ".chip_for" do
    # Regression: class instance variables in Ruby do NOT inherit
    # through `<`. Before the fix, AgentProvider (EnumColumn subclass)
    # reported bucket="" and operators=[] — the chip-bar UI fell back
    # to free-text input instead of an enum dropdown.
    it "inherits bucket from a bucket base class (EnumColumn)" do
      schema = described_class.chip_for("agent_provider")
      expect(schema["bucket"]).to eq("enum")
      expect(schema["operators"]).to include("is", "is_one_of", "is_set")
      expect(schema["values"]).to eq([
        { "value" => "claude", "label" => "Claude" },
        { "value" => "codex",  "label" => "Codex" }
      ])
    end

    it "inherits string operators from StringColumn base" do
      schema = described_class.chip_for("title")
      expect(schema["bucket"]).to eq("string")
      expect(schema["operators"]).to include(
        "contains", "does_not_contain",
        "starts_with", "ends_with",
        "equals", "is_set"
      )
    end

    it "inherits date operators from DateColumn base" do
      schema = described_class.chip_for("created_at")
      expect(schema["bucket"]).to eq("date")
      expect(schema["operators"]).to be_present
    end

    it "inherits number operators from NumberColumn base" do
      schema = described_class.chip_for("issue_number")
      expect(schema["bucket"]).to eq("number")
      expect(schema["operators"]).to be_present
    end

    it "still respects per-chip overrides for bucket and values" do
      schema = described_class.chip_for("priority")
      expect(schema["bucket"]).to eq("enum")
      expect(schema["values"].map { |v| v["value"] }).to eq(%w[high medium low])
    end

    it "embeds preset expansions on chips that declare them" do
      schema = described_class.chip_for("attention")
      expect(schema["expansions"]).to be_a(Hash)
      expect(schema["expansions"].keys).to include("stale", "blocked", "pinned")
      expect(schema["expansions"]["pinned"]).to eq(
        "field" => "pinned_by_me", "op" => "is_true", "value" => nil
      )
    end

    it "omits the expansions key for chips that don't declare them" do
      schema = described_class.chip_for("priority")
      expect(schema).not_to have_key("expansions")
    end

    it "populates values for triaging_reason from the Job constant" do
      schema = described_class.chip_for("triaging_reason")
      expect(schema["values"].map { |v| v["value"] }).to match_array(Job::TRIAGING_REASONS)
    end

    it "populates values for age from CUTOFFS" do
      schema = described_class.chip_for("age")
      expect(schema["values"].map { |v| v["value"] }).to eq(%w[1d 7d 30d])
    end

    it "humanizes enum value labels (acronyms, sentence-case)" do
      labels = described_class.chip_for("closure_reason")["values"].to_h { |v| [ v["value"], v["label"] ] }
      expect(labels["pr_merged"]).to eq("PR merged")
      expect(labels["external_pr_merged"]).to eq("External PR merged") if labels.key?("external_pr_merged")
    end

    it "renders pr_mergeable as a boolean tri-state chip" do
      schema = described_class.chip_for("pr_mergeable")
      expect(schema["bucket"]).to eq("boolean")
      expect(schema["operators"]).to eq(%w[is_true is_false is_set is_unset])
      expect(schema["values"]).to eq([])
    end

    it "strips is_set / is_unset from non-nullable date columns" do
      schema = described_class.chip_for("created_at")
      expect(schema["operators"]).to eq(%w[before after between within_last more_than_ago])
      expect(schema["operators"]).not_to include("is_set", "is_unset")
    end

    it "keeps is_set / is_unset on nullable date columns" do
      schema = described_class.chip_for("finished_at")
      expect(schema["operators"]).to include("is_set", "is_unset")
    end

    it "renders Epic-subject metadata from the Epic chip set" do
      schema = described_class.for(subject: :epic)
      fields = schema.map { |chip| chip["field"] }

      expect(fields).to match_array(Filters::SUBJECTS.fetch(:epic).fields)
      expect(schema.find { |chip| chip["field"] == "state" }["values"].map { |v| v["value"] }).to eq(Epic::STATES)
      expect(schema.find { |chip| chip["field"] == "attention" }["values"].map { |v| v["value"] }).to include("ready_to_start", "recently_done")
    end
  end
end
