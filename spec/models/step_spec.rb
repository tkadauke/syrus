require "rails_helper"

RSpec.describe Step do
  let(:job)      { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }

  def build_step(**overrides)
    described_class.new({ workflow: workflow, kind: "implement", position: 0 }.merge(overrides))
  end

  describe "validations" do
    it "accepts every documented kind" do
      Step::KINDS.each_with_index do |k, i|
        expect(build_step(kind: k, position: i)).to be_valid, "expected #{k} to be a valid kind"
      end
    end

    it "rejects unknown kinds" do
      expect(build_step(kind: "vibes")).not_to be_valid
    end

    it "requires non-negative position" do
      expect(build_step(position: -1)).not_to be_valid
    end
  end

  describe "loop iteration columns" do
    it "defaults iteration to 1 and loop_id to nil" do
      step = described_class.create!(workflow: workflow, kind: "implement", position: 0)

      expect(step.iteration).to eq(1)
      expect(step.loop_id).to be_nil
    end

    it "has the loop lookup index" do
      index = ActiveRecord::Base.connection.indexes(:steps).find do |idx|
        idx.columns == %w[ workflow_id loop_id iteration ]
      end

      expect(index).to be_present
    end
  end

  describe "#agentic?" do
    it "is true for kinds that spawn an agent" do
      %w[ implement summarize respond summarize_amend analyze_and_fix agent_rebase manual ].each do |k|
        expect(build_step(kind: k).agentic?).to be(true), "expected #{k} to be agentic"
      end
    end

    it "is false for kinds that just run service code" do
      %w[ pr_open push auto_rebase force_push ].each do |k|
        expect(build_step(kind: k).agentic?).to be(false), "expected #{k} to be non-agentic"
      end
    end
  end

  describe "AASM state machine" do
    let(:step) { described_class.create!(workflow: workflow, kind: "implement", position: 0) }

    it "starts queued" do
      expect(step.state).to eq("queued")
    end

    it "queued → running stamps started_at" do
      freeze_time do
        step.start!
        step.save!
        expect(step.started_at).to eq(Time.current)
      end
    end

    it "running → succeeded stamps finished_at" do
      step.start!
      freeze_time do
        step.succeed!
        step.save!
        expect(step.finished_at).to eq(Time.current)
      end
    end
  end

  describe "linear chain navigation" do
    let!(:step_a) { described_class.create!(workflow: workflow, kind: "implement", position: 0) }
    let!(:step_b) { described_class.create!(workflow: workflow, kind: "summarize", position: 1) }
    let!(:step_c) { described_class.create!(workflow: workflow, kind: "pr_open",   position: 2) }

    before do
      step_a.update!(next_step_id: step_b.id)
      step_b.update!(next_step_id: step_c.id)
    end

    it "exposes next_step" do
      expect(step_a.next_step).to eq(step_b)
      expect(step_b.next_step).to eq(step_c)
      expect(step_c.next_step).to be_nil
    end

    it "exposes previous_step" do
      expect(step_b.previous_step).to eq(step_a)
      expect(step_c.previous_step).to eq(step_b)
      expect(step_a.previous_step).to be_nil
    end
  end

  describe "advancement on succeed" do
    it "calls StepDispatcher.advance_from when state transitions to succeeded" do
      step = described_class.create!(workflow: workflow, kind: "implement", position: 0)
      step.start!
      expect(StepDispatcher).to receive(:advance_from).with(step)
      step.succeed!
      step.save!
    end

    it "does not call StepDispatcher.advance_from on other transitions" do
      step = described_class.create!(workflow: workflow, kind: "implement", position: 0)
      expect(StepDispatcher).not_to receive(:advance_from)
      step.start!
      step.save!
    end
  end

  describe "#upstream_session_id" do
    let!(:step_a) { described_class.create!(workflow: workflow, kind: "implement", position: 0) }
    let!(:step_b) { described_class.create!(workflow: workflow, kind: "summarize", position: 1) }
    before { step_a.update!(next_step_id: step_b.id) }

    it "returns nil when there's no upstream step" do
      expect(step_a.upstream_session_id).to be_nil
    end

    it "returns nil when the upstream step hasn't succeeded yet" do
      expect(step_b.upstream_session_id).to be_nil
    end

    it "returns the latest succeeded run's claude_session.session_id" do
      step_a.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      run = Run.create!(job: job, step: step_a, trigger_kind: "initial", state: "succeeded")
      ClaudeSession.create!(run: run, session_id: "S-upstream", transcript_jsonl: "x")
      expect(step_b.upstream_session_id).to eq("S-upstream")
    end
  end
end
