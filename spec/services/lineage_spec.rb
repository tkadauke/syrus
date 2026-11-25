require "rails_helper"

# NY40: the hierarchical row-lock order (parents before children). Lineage.lock!
# takes a record's ancestry top-down, so a transaction that then writes up the
# tree (a rollup) only touches rows it already holds.
RSpec.describe Lineage do
  let(:job) { Factories.job }
  let(:workflow) { job.reload.workflows.order(:id).last }
  let(:step) { workflow.steps.order(:position).first }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind) }

  around do |example|
    previous_mode = Syrus::LockOrder::Checker.mode
    previous_writes = ENV["SYRUS_LOCK_ORDER_WRITES"]
    Syrus::LockOrder::Checker.mode = :raise
    ENV["SYRUS_LOCK_ORDER_WRITES"] = "1"
    example.run
  ensure
    Syrus::LockOrder::Checker.mode = previous_mode
    ENV["SYRUS_LOCK_ORDER_WRITES"] = previous_writes
  end

  it "names a Run's whole ancestry, top down" do
    expect(described_class.ancestry(run).map(&:first)).to eq(
      [ Job, WorkIntent, WorkUnit, Workflow, Step, Run ].tap { |models| models.unshift(Epic) if job.epic_id }
    )
  end

  it "makes a rollup from a Run up to its Job and WorkUnit lock in order" do
    run
    expect {
      ActiveRecord::Base.transaction do
        described_class.lock!(run)
        run.update_columns(updated_at: Time.current)
        step.update_columns(updated_at: Time.current)
        workflow.update_columns(updated_at: Time.current)
        workflow.work_unit.update_columns(updated_at: Time.current)
        job.update_columns(updated_at: Time.current)
      end
    }.not_to raise_error
  end

  it "is what makes the rollup legal: without it the same writes break the order" do
    run # created before the transaction: a row the transaction inserts is outside the order
    expect {
      ActiveRecord::Base.transaction do
        run.update_columns(updated_at: Time.current)
        job.update_columns(updated_at: Time.current)
      end
    }.to raise_error(Syrus::LockOrder::Error, /took Job .* while holding Run/)
  end

  it "keeps unsaved changes on the record it is given" do
    run.prompt = "unsaved"

    described_class.lock!(run)

    expect(run.prompt).to eq("unsaved")
  end
end
