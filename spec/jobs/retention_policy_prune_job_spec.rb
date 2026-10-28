require "rails_helper"

RSpec.describe RetentionPolicyPruneJob do
  it "deletes only eligible rows for a registered policy" do
    user = Factories.user
    old = Notification.create!(user:, kind: "job_failed", body: "Old", created_at: 31.days.ago)
    fresh = Notification.create!(user:, kind: "job_failed", body: "Fresh", created_at: 1.day.ago)

    described_class.perform_now("notification")

    expect(Notification.exists?(old.id)).to be(false)
    expect(Notification.exists?(fresh.id)).to be(true)
  end

  it "is a no-op for infinite retention" do
    set_retention(:notification, 0)
    old = Notification.create!(user: Factories.user, kind: "job_failed", body: "Old", created_at: 10.years.ago)

    described_class.perform_now("notification")

    expect(Notification.exists?(old.id)).to be(true)
  end

  it "archives an enabled archivable policy before deleting" do
    set_retention_archive(:run_diagnostic, true)
    old = RunDiagnostic.create!(run: Factories.run, error_class: "Error")
    old.update_columns(created_at: 31.days.ago)

    expect { described_class.perform_now("run_diagnostic") }.to change(RetentionArchive, :count).by(1)
    expect(RetentionArchive.last).to have_attributes(retention_key: "run_diagnostic", row_count: 1)
    expect(RunDiagnostic.exists?(old.id)).to be(false)
  end

  it "re-enqueues only the capped policy when eligible rows remain" do
    executor = instance_double(RetentionPolicyExecutors::Default)
    definition = instance_double(RetentionPolicyRegistry::Definition, key: :notification, executor: executor)
    allow(RetentionPolicyRegistry).to receive(:fetch).with("notification").and_return(definition)
    allow(executor).to receive(:call).and_return(
      RetentionPolicyExecutors::Result.new(deleted_count: 50_000, backlog: true)
    )

    expect { described_class.perform_now("notification") }
      .to have_enqueued_job(described_class).with("notification").once
  end

  it "deduplicates overlap by retention key while allowing different keys" do
    expect(described_class.concurrency_key.call("notification")).to eq("retention:notification")
    expect(described_class.concurrency_key.call("run_diagnostic")).to eq("retention:run_diagnostic")
  end

  it "emits standardized count, duration, backlog, and failure telemetry" do
    described_class.perform_now("notification")
    success_metrics = Syrus::Metrics.render

    expect(success_metrics).to include('syrus_retention_rows_pruned_total{retention_key="notification"}')
    expect(success_metrics).to include('syrus_retention_prune_duration_seconds_count{retention_key="notification"}')
    expect(success_metrics).to include('syrus_retention_prune_backlog{retention_key="notification"} 0')

    allow(RetentionPolicyRegistry).to receive(:fetch).with("missing").and_raise(KeyError)
    expect { described_class.perform_now("missing") }.to raise_error(KeyError)
    expect(Syrus::Metrics.render).to include('syrus_retention_prune_failures_total{retention_key="missing"} 1')
  end

  it "propagates one policy failure without consuming another policy's job" do
    failing = instance_double(RetentionPolicyRegistry::Definition, key: :notification)
    allow(RetentionPolicyRegistry).to receive(:fetch).and_call_original
    allow(RetentionPolicyRegistry).to receive(:fetch).with("notification").and_return(failing)
    allow(failing).to receive(:executor).and_raise("broken policy")

    expect { described_class.perform_now("notification") }.to raise_error("broken policy")
    expect { described_class.perform_now("run_resource_summary") }.not_to raise_error
  end
end
