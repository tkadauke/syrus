require "rails_helper"

RSpec.describe WorkIntents::Scheduler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:intent) do
    WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      actor: user
    )
  end

  it "marks an intent waiting when a gate returns a typed wait result" do
    gate = Class.new do
      REASON = "policy_not_eligible"

      def self.call(_intent)
        WorkIntents::GateResult.wait(reason: REASON, retry_at: 1.minute.from_now, details: { "policy" => "closed" })
      end
    end

    result = described_class.evaluate!(intent, gates: [ gate ])

    expect(result).to be_waiting
    expect(intent.reload).to have_attributes(state: "waiting", wait_reason: "policy_not_eligible")
    expect(intent.wait_details).to include("policy" => "closed")
  end

  it "clears a managed wait reason when its gates pass" do
    intent.wait!(reason: "dependency", details: { "blocked_by_job_ids" => [ 99 ] })

    result = described_class.evaluate!(intent, gates: [ WorkIntents::Gates::Dependency ])

    expect(result).to be_pass
    expect(intent.reload).to have_attributes(state: "requested", wait_reason: nil)
  end

  it "does not clear a wait reason outside the evaluated gates" do
    intent.wait!(reason: "approval", details: { "reviewers" => [ "owner" ] })

    result = described_class.evaluate!(intent, gates: [ WorkIntents::Gates::Dependency ])

    expect(result).to be_pass
    expect(intent.reload).to have_attributes(state: "waiting", wait_reason: "approval")
  end

  it "uses dependency as a default definition gate" do
    blocker = Factories.job_record(user: user, repository: repository, state: "implemented", issue_number: 99)
    JobDependency.create!(job: job, depends_on_job: blocker, source: "manual")

    result = described_class.evaluate!(intent)

    expect(result).to be_waiting
    expect(intent.reload).to have_attributes(state: "waiting", wait_reason: "dependency")
    expect(intent.wait_details).to include("blocked_by_job_ids" => [ blocker.id ])
  end
end
