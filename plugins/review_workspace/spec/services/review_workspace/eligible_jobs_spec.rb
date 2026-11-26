require "rails_helper"

RSpec.describe ReviewWorkspacePlugin::EligibleJobs do
  let!(:instance_admin) { Factories.user }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true) }

  def implemented(**attributes)
    Factories.job_record(
      user:, repository:, state: "implemented", issue_number: SecureRandom.random_number(100_000),
      issue_title: "Ready for review", finished_at: 1.hour.ago, **attributes
    )
  end

  it "returns only visible, writable, non-investigation Jobs the user can approve" do
    eligible = implemented
    implemented(investigation: true)
    implemented(state: "running")
    Factories.job_record(user:, repository:, state: "implemented", kind: "main_grader", issue_number: nil)
    disabled_repository = Factories.repository(user:, auto_merge_enabled: false)
    Factories.job_record(user:, repository: disabled_repository, state: "implemented")
    already_voted = implemented
    JobApproval.create!(job: already_voted, user:, approved_at: Time.current)

    other_user = Factories.user(global_role: "user")
    hidden_repository = Factories.repository(user: other_user)
    Factories.job_record(user: other_user, repository: hidden_repository, state: "implemented")

    expect(described_class.call(user:)).to eq([ eligible ])
  end

  it "excludes manually paused Jobs" do
    eligible = implemented
    implemented(manual_paused: true, manual_paused_at: Time.current)

    expect(described_class.call(user:)).to eq([ eligible ])
  end

  it "includes implemented Jobs regardless of active runtime work" do
    implementation_running = Factories.job_with_run(user:, repository:, state: "implemented", run_attrs: { state: "running", trigger_kind: "initial" })
    review_running = Factories.job_with_run(user:, repository:, state: "implemented", run_attrs: { state: "running", trigger_kind: "manual_visual_review" })

    expect(described_class.call(user:)).to contain_exactly(implementation_running, review_running)
  end

  it "orders unblocked dependencies first, then priority, ready age, and id" do
    old_medium = implemented(priority: "medium", finished_at: 3.hours.ago)
    new_high = implemented(priority: "high", finished_at: 1.hour.ago)
    blocked_urgent = implemented(priority: "urgent", finished_at: 4.hours.ago)
    dependency = Factories.job_record(user:, repository:, state: "running", issue_number: 999_991)
    JobDependency.create!(job: blocked_urgent, depends_on_job: dependency, source: "manual")

    expect(described_class.call(user:).map(&:id)).to eq([ new_high.id, old_medium.id, blocked_urgent.id ])
  end

  it "keeps query count bounded as the stack grows" do
    implemented
    described_class.call(user:)
    one_count = query_count { described_class.call(user:) }
    8.times { implemented }

    expect(query_count { described_class.call(user:) }).to be <= one_count + 2
  end

  def query_count
    count = 0
    callback = lambda do |_name, _started, _finished, _id, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
