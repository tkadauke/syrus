require "rails_helper"

RSpec.describe InvariantMonitorJob do
  def stranded_approved_job
    job = Factories.job_with_run(state: "approved", workflow_attrs: { state: "succeeded" }, run_attrs: { state: "succeeded" })
    job.update_columns(approved_at: Time.current)
    job
  end

  it "is scheduled as a recurring task" do
    recurring = YAML.load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)

    expect(recurring.dig("production", "monitor_invariants")).to include("class" => "InvariantMonitorJob", "queue" => "low_priority_maintenance")
  end

  it "records violations, logs newly opened ones, and resolves them once they clear" do
    job = stranded_approved_job
    allow(Rails.logger).to receive(:warn)

    described_class.perform_now(now: Time.current + 3.hours)

    record = InvariantViolation.open.sole
    expect(record).to have_attributes(invariant_key: "landing_progress", subject_type: "Job", subject_id: job.id, severity: "critical")
    expect(Rails.logger).to have_received(:warn).with(/violation opened landing_progress:Job:#{job.id}/)

    job.update_columns(state: "closed")
    described_class.perform_now(now: Time.current + 4.hours)

    expect(InvariantViolation.open).to be_empty
    expect(record.reload.resolved_at).to be_present
  end

  it "logs an invariant that raised and keeps recording the rest" do
    stranded_approved_job
    allow(Invariants::RetryStorms).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(now: Time.current + 3.hours)

    expect(Rails.logger).to have_received(:error).with(/retry_storms raised ActiveRecord::StatementInvalid/)
    expect(InvariantViolation.open.pluck(:invariant_key)).to eq(%w[landing_progress])
  end
end
