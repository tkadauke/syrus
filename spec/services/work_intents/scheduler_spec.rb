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

  it "marks landing intents waiting when approval was withdrawn before launch" do
    landing_intent = WorkIntent.create!(
      kind: "auto_merge",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      actor: user
    )

    result = described_class.evaluate!(landing_intent)

    expect(result).to be_waiting
    expect(landing_intent.reload).to have_attributes(state: "waiting", wait_reason: "approval")
    expect(landing_intent.wait_details).to include("waiting_job_ids" => [ job.id ])
  end

  it "allows landing intents for jobs already approved or landing" do
    job.update!(state: "approved")
    landing_intent = WorkIntent.create!(
      kind: "auto_merge",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      actor: user
    )

    expect(described_class.evaluate!(landing_intent)).to be_pass

    job.update!(state: "landing")
    landing_intent.wait!(reason: "approval", details: { "waiting_job_ids" => [ job.id ] })

    expect(described_class.evaluate!(landing_intent)).to be_pass
    expect(landing_intent.reload).to have_attributes(state: "requested", wait_reason: nil)
  end

  it "marks merge-train intents waiting until every open epic child is approved or landing" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 201)
    waiting = Factories.job_record(user: user, repository: repository, epic: epic, state: "implemented", issue_number: 202)
    train_intent = WorkIntent.create!(
      kind: "merge_train",
      state: "requested",
      repository: repository,
      scope_type: "epic",
      scope_id: epic.id,
      actor: user
    )

    result = described_class.evaluate!(train_intent)

    expect(result).to be_waiting
    expect(train_intent.reload).to have_attributes(state: "waiting", wait_reason: "approval")
    expect(train_intent.wait_details).to include("waiting_job_ids" => [ waiting.id ])
  end
end
