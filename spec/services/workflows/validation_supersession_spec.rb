require "rails_helper"

RSpec.describe Workflows::ValidationSupersession do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository) }

  def workflow(state:, trigger_kind: "initial", finished_at: nil, created_at: nil)
    Workflow.create!(job: job, user: user, trigger_kind: trigger_kind, state: state,
      finished_at: finished_at, created_at: created_at || Time.current)
  end

  def validation_kind
    described_class.validation_step_kinds.first
  end

  describe ".successful_validation_workflow_after?" do
    it "is true when a later succeeded Workflow has a succeeded validation Step" do
      source = workflow(state: "failed", finished_at: 10.minutes.ago, created_at: 10.minutes.ago)
      later = workflow(state: "succeeded", created_at: 1.minute.ago)
      Step.create!(workflow: later, kind: validation_kind, position: 1, state: "succeeded")

      expect(described_class.successful_validation_workflow_after?(source)).to be(true)
    end

    it "is false when the later succeeded Workflow's validation Step did not succeed" do
      source = workflow(state: "failed", finished_at: 10.minutes.ago, created_at: 10.minutes.ago)
      later = workflow(state: "succeeded", created_at: 1.minute.ago)
      Step.create!(workflow: later, kind: validation_kind, position: 1, state: "failed")

      expect(described_class.successful_validation_workflow_after?(source)).to be(false)
    end

    it "is false when the only succeeded Workflow predates the source" do
      earlier = workflow(state: "succeeded", created_at: 20.minutes.ago)
      Step.create!(workflow: earlier, kind: validation_kind, position: 1, state: "succeeded")
      source = workflow(state: "failed", finished_at: 1.minute.ago, created_at: 1.minute.ago)

      expect(described_class.successful_validation_workflow_after?(source)).to be(false)
    end

    it "is false when there is no later Workflow at all" do
      source = workflow(state: "failed", finished_at: 1.minute.ago, created_at: 1.minute.ago)

      expect(described_class.successful_validation_workflow_after?(source)).to be(false)
    end

    it "does not sort wide rows when scanning several later Workflows" do
      source = workflow(state: "failed", finished_at: 30.minutes.ago, created_at: 30.minutes.ago)
      # Several later succeeded Workflows, so the Step load batches their ids
      # into an IN list. With one there is no IN list and no regression to see.
      3.times do |index|
        later = workflow(state: "succeeded", created_at: (3 - index).minutes.ago)
        Step.create!(workflow: later, kind: "grader", position: 1, state: "succeeded",
          details: { "output" => "x" * 2_048 })
      end

      offenders = wide_row_sort_statements do
        described_class.successful_validation_workflow_after?(source)
      end

      expect(offenders).to be_empty
    end

    it "walks Steps back to the Workflow instance they were attached to" do
      source = workflow(state: "failed", finished_at: 10.minutes.ago, created_at: 10.minutes.ago)
      later = workflow(state: "succeeded", created_at: 1.minute.ago)
      Step.create!(workflow: later, kind: validation_kind, position: 1, state: "succeeded")

      # Exercises the inverse the hand-rolled preload has to set: if
      # `step.workflow` re-queried here, this would emit extra statements.
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] if payload[:sql].match?(/FROM [`"]?workflows[`"]?/i)
      end
      begin
        described_class.successful_validation_workflow_after?(source)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(statements.size).to eq(1)
    end
  end

  describe ".superseded_by_successful_workflow?" do
    it "is false without a source" do
      expect(described_class.superseded_by_successful_workflow?(nil)).to be(false)
    end

    it "uses the plain successful-workflow check for a non-repair source" do
      source = workflow(state: "failed", trigger_kind: "initial",
        finished_at: 10.minutes.ago, created_at: 10.minutes.ago)
      later = workflow(state: "succeeded", created_at: 1.minute.ago)
      # No validation Step: the plain check only cares that one succeeded.
      Step.create!(workflow: later, kind: "implement", position: 1, state: "succeeded")

      expect(described_class.superseded_by_successful_workflow?(source)).to be(true)
    end
  end
end
