require "rails_helper"
require Rails.root.join("plugins/test_insights/db/migrate/20261101171504_canonicalize_test_insight_identities")

RSpec.describe CanonicalizeTestInsightIdentities do
  subject(:migration) { described_class.new }

  let(:repository) { Factories.repository }
  let(:test_run) do
    TestInsights::TestRun.create!(
      run: Factories.job(repository: repository).initial_run,
      repository: repository,
      grader_name: "rspec",
      total_count: 2,
      passed_count: 1,
      failed_count: 1,
      skipped_count: 0,
      error_count: 0
    )
  end

  it "merges suite-based identities without losing their historical cases" do
    old_suite = create_identity!("Old::WidgetSpec")
    renamed_suite = create_identity!("Renamed::WidgetSpec")
    create_case!(old_suite, "passed", 2.days.ago)
    create_case!(renamed_suite, "failed", 1.day.ago)
    TestInsights::RuntimeSummary.create!(
      repository: repository, test_identity: old_suite, grader_name: "rspec", window: "recent_100", sample_count: 1
    )

    migration.migrate(:up)

    identity = TestInsights::TestIdentity.find_by!(repository: repository)
    expect(identity).to have_attributes(
      fingerprint: TestInsights::TestIdentity.fingerprint_for(
        suite_name: "irrelevant", file_path: "spec/models/widget_spec.rb", name: "does the thing"
      ),
      suite_name: "spec/models/widget_spec.rb",
      recent_sample_count: 2,
      recent_failed_count: 1,
      recent_passed_count: 1
    )
    expect(identity.test_cases.order(:created_at).pluck(:status)).to eq(%w[passed failed])
    expect(TestInsights::TestCase.flakiness_score(
      repository: repository, suite_name: identity.suite_name, name: identity.name
    )).to include(flaky: true, failed_count: 1, total_count: 2)
    expect(TestInsights::RuntimeSummary.where(test_identity_id: [ old_suite.id, renamed_suite.id ])).to be_empty
  end

  it "is idempotent" do
    identity = create_identity!("Old::WidgetSpec")
    create_case!(identity, "failed", 1.day.ago)

    2.times { migration.migrate(:up) }

    expect(TestInsights::TestIdentity.where(repository: repository).count).to eq(1)
    expect(TestInsights::TestCase.where(repository: repository).count).to eq(1)
  end

  private

  def create_identity!(suite_name)
    TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: Digest::SHA256.hexdigest([ suite_name, "does the thing" ].join("\0")),
      suite_name: suite_name,
      name: "does the thing",
      file_path: "spec/models/widget_spec.rb"
    )
  end

  def create_case!(identity, status, created_at)
    TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      file_path: identity.file_path,
      status: status,
      created_at: created_at,
      updated_at: created_at
    )
  end
end
