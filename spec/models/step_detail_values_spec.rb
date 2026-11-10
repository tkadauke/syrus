require "rails_helper"
require Rails.root.join("db/migrate/20261110162838_create_step_detail_values")

RSpec.describe "Step externalized details" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) do
    workflow.steps.create!(kind: "grader", position: 90, state: "queued", details: { "name" => "rspec", "command" => "bin/rspec" })
  end

  def sql_during
    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| statements << p[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "lists output as the only externalized key" do
    expect(StepDetailValue::EXTERNALIZED_KEYS).to eq(%w[ output ])
  end

  it "stores output in the side table, not the inline column" do
    step.update!(details: step.details.to_h.merge("output" => "boom"))

    expect(step.reload.inline_details).to eq("name" => "rspec", "command" => "bin/rspec")
    expect(StepDetailValue.where(step_id: step.id).pluck(:key, :value)).to eq([ [ "output", "boom" ] ])
    expect(step.details).to eq("name" => "rspec", "command" => "bin/rspec", "output" => "boom")
  end

  it "returns the plain hash for a step without output" do
    expect(step.reload.details).to eq("name" => "rspec", "command" => "bin/rspec")
  end

  it "reads output still inline from before the backfill" do
    step.update_columns(details: { "name" => "rspec", "output" => "legacy" })

    expect(step.reload.details).to eq("name" => "rspec", "output" => "legacy")
  end

  it "prefers the side-table value over a stale inline one" do
    step.update_columns(details: { "output" => "old" })
    StepDetailValue.create!(step_id: step.id, key: "output", value: "new")

    expect(step.reload.details["output"]).to eq("new")
  end

  it "round-trips allowlisted and non-allowlisted keys through the merge pattern" do
    step.update!(details: step.details.to_h.merge("output" => "one", "exit_code" => 1))
    step = Step.find(self.step.id)
    step.update!(details: step.details.to_h.merge("output" => "two", "extra" => "x"))

    reloaded = Step.find(step.id)
    expect(reloaded.details).to include("output" => "two", "exit_code" => 1, "extra" => "x", "name" => "rspec")
    expect(reloaded.inline_details.keys).not_to include("output")
    expect(StepDetailValue.where(step_id: step.id).count).to eq(1)
  end

  it "removes output when a rewritten bag omits it" do
    step.update!(details: step.details.to_h.merge("output" => "one"))
    step.update!(details: step.details.to_h.except("output"))

    expect(StepDetailValue.where(step_id: step.id)).to be_empty
  end

  it "does not query or select the side table when loading a step" do
    step.update!(details: step.details.to_h.merge("output" => "boom"))

    statements = sql_during do
      loaded = Step.find(step.id)
      [ loaded.state, loaded.position, loaded.inline_details ]
    end

    expect(statements.grep(/step_detail_values/)).to be_empty
  end

  it "queries the side table only when details is read" do
    step.update!(details: step.details.to_h.merge("output" => "boom"))
    loaded = Step.find(step.id)

    statements = sql_during { loaded.details; loaded.details }

    expect(statements.grep(/step_detail_values/).size).to eq(1)
  end

  it "keeps externalized output through update_details_columns!" do
    step.update_details_columns!(step.details.to_h.merge("output" => "cols", "k" => 1), cancellation_reason: nil)

    reloaded = Step.find(step.id)
    expect(reloaded.details).to include("output" => "cols", "k" => 1)
    expect(reloaded.inline_details.keys).not_to include("output")
  end

  it "destroys side-table rows with the step" do
    step.update!(details: step.details.to_h.merge("output" => "boom"))

    expect { step.destroy! }.to change { StepDetailValue.count }.by(-1)
  end

  describe "paths that merge into the bag" do
    it "keeps output and adds skip markers when skipped" do
      step.update!(details: step.details.to_h.merge("output" => "boom"))
      Step.find(step.id).skip_with_reason!("because")

      expect(Step.find(step.id).details).to include("skipped" => true, "skip_reason" => "because", "output" => "boom", "name" => "rspec")
    end

    it "keeps the structural keys when cancelled with attribution details" do
      step.update!(details: step.details.to_h.merge("output" => "boom", "cancelled_reason" => "r"))
      cleaned = Step.find(step.id)
      cleaned.update_details_columns!(cleaned.details.to_h.except(*Step::CANCELLATION_DETAIL_KEYS))

      expect(Step.find(step.id).details).to eq("name" => "rspec", "command" => "bin/rspec", "output" => "boom")
    end
  end

  describe "backfill migration" do
    let(:migration) { CreateStepDetailValues.new }

    it "moves output out of inline details, keeps structural keys, and is idempotent" do
      step.update_columns(details: { "name" => "rspec", "output" => "legacy", "exit_code" => 2 })

      2.times { migration.send(:backfill) }

      expect(step.reload.inline_details).to eq("name" => "rspec", "exit_code" => 2)
      expect(StepDetailValue.where(step_id: step.id).pluck(:key, :value)).to eq([ [ "output", "legacy" ] ])
      expect(step.details["output"]).to eq("legacy")
    end
  end
end
