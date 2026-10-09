require "rails_helper"
require "ostruct"

RSpec.describe IngestionClassifier do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:github_client) { instance_double(GithubClient, list_pull_requests_for_triage: []) }

  # The classifier goes through Judgment now, so the seam is the provider call
  # every other one-shot caller stubs.
  def stub_agent_text(text, spawned_process_id: nil)
    allow(AgentProviders).to receive(:run_one_shot).and_return(
      AgentInvocation::Result.new(
        turns: 1, exit_status: 0, timed_out: false, is_error: false,
        outcome: "success", final_text: text, session_id: nil, spawned_process_id: spawned_process_id
      )
    )
  end

  def classify(job, json, client: github_client)
    stub_agent_text(JSON.generate(json))
    described_class.call(job: job, github_client: client)
  end

  before do
    allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(
      RepoDefaultBranchSyrusYml::Result.new(config: nil, source: "none", note: "no .syrus.yml", outcome: :absent)
    )
  end

  it "marks a duplicate issue invalid with the original issue URL as evidence" do
    original = Job.create!(
      user: user,
      repository: repository,
      issue_number: 10,
      issue_title: "Add status filters",
      issue_body: "Let operators filter the dashboard by run status."
    )
    original.advance_after_triage!
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 11,
      issue_title: "Dashboard status filters",
      issue_body: "Add filters so operators can filter by run status."
    )
    evidence_url = "https://github.com/acme/widgets/issues/10"

    classify(job, {
      "epic_id" => nil,
      "invalid" => {
        "kind" => "duplicate",
        "reason" => "This matches the existing status-filter Job.",
        "evidence_urls" => [ evidence_url ]
      }
    })

    expect(job.reload).to have_attributes(
      state: "closed",
      closure_reason: "duplicate",
      validity: "duplicate",
      invalidation_reason: "This matches the existing status-filter Job.",
      invalidation_evidence: [ evidence_url ]
    )
    expect(job.runs).to be_empty
  end

  it "marks already-implemented issues invalid with merged PR evidence" do
    pr = OpenStruct.new(
      number: 32,
      title: "Ship status filters",
      body: "Adds dashboard filters.",
      html_url: "https://github.com/acme/widgets/pull/32",
      merged_at: 2.days.ago
    )
    client = instance_double(GithubClient, list_pull_requests_for_triage: [ pr ])
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 12,
      issue_title: "Add status filters",
      issue_body: "Operators need dashboard filters."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => {
        "kind" => "already_implemented",
        "reason" => "PR #32 already added dashboard status filters.",
        "evidence_urls" => [ "https://github.com/acme/widgets/pull/32" ]
      }
    }, client: client)

    expect(job.reload).to have_attributes(
      state: "closed",
      closure_reason: "already_implemented",
      validity: "already_implemented",
      invalidation_evidence: [ "https://github.com/acme/widgets/pull/32" ]
    )
  end

  it "assigns a strong Epic match and advances through the normal triage flow" do
    epic = Factories.epic(user: user, repository: repository, state: "backlog", title: "Dashboard cleanup")
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 13,
      issue_title: "Add status filters",
      issue_body: "This belongs with the dashboard cleanup work."
    )

    classify(job, {
      "epic_id" => epic.id,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    })

    expect(job.reload.epic).to eq(epic)
    expect(job.state).to eq("blocked_by_epic")
    expect(job.runs).to be_empty
  end

  it "queues a clear novel issue through the normal triage flow" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 14,
      issue_title: "Add a new report",
      issue_body: "Build a novel operator report."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    })

    expect(job.reload.state).to eq("queued")
    expect(job.validity).to eq("valid")
    expect(job.runs.count).to eq(1)
  end

  it "records timing and decision for a successful classification attempt" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 114,
      issue_title: "Add a new report",
      issue_body: "Build a novel operator report."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    })

    attempt = job.reload.classification_attempts.sole
    expect(attempt).to have_attributes(
      started_at: be_present,
      finished_at: be_present,
      outcome: "classified",
      error: nil,
      agent_provider: job.workflow_agent_provider
    )
    expect(attempt.decision).to include("epic_id" => nil)
    expect(attempt.raw_output).to include("epic_id")
  end

  it "persists a classifier-selected planned execution requirement before queueing" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 141,
      issue_title: "Fix iOS build",
      issue_body: "The Xcode project no longer builds."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] },
      "planned_execution" => {
        "project_label" => "iOS",
        "target_label" => "//ios:app",
        "capabilities" => {
          "os" => [ "macos" ],
          "arch" => [ "arm64" ],
          "toolchain" => [ "xcode" ],
          "runtime" => [ "ios_simulator" ]
        }
      }
    })

    expect(job.reload.planned_execution_json).to include(
      "project_label" => "iOS",
      "target_label" => "//ios:app",
      "capabilities" => {
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchain" => [ "xcode" ],
        "runtime" => [ "ios_simulator" ]
      },
      "source" => "classifier"
    )
    expect(job.state).to eq("queued")
  end

  # Naming several platforms used to strand the Job in triage, because
  # placement was inferred from the issue text and two keyword lists matched.
  # The text is not read for placement any more, so an issue mentioning
  # platforms is ordinary work: it queues on the Linux default, and a Job that
  # truly needs another host gets `planned_execution` from the classifier.
  it "queues an issue naming several platforms on the default host" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 142,
      issue_title: "Build iOS and Windows apps",
      issue_body: "Update the Xcode project and Windows installer."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] },
      "planned_execution" => nil
    })

    expect(job.reload).not_to be_triaging
    expect(job.planned_execution_capabilities).to eq("os" => [ "linux" ])
  end

  it "marks classifier failures as uncertain without queueing the job" do
    job = Job.create!(user: user, repository: repository, issue_number: 15)
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "not json",
      session_id: nil
    )
    allow(AgentProviders).to receive(:run_one_shot).and_return(result)

    described_class.call(job: job, github_client: github_client)

    expect(job.reload).to be_triaging
    expect(job.triaging_reason).to eq("classifier_uncertain")
    expect(job.runs).to be_empty
  end

  # The reason used to go to Rails.logger.warn and nowhere else, so by the time
  # anyone noticed the Job was stuck the logs were gone and there was no way to
  # tell a transient provider error from an issue that needs a person.
  it "records why the classifier gave up" do
    job = Job.create!(user: user, repository: repository, issue_number: 16)
    stub_agent_text("not json")

    described_class.call(job: job, github_client: github_client)

    expect(job.reload.triaging_uncertainty_reason).to be_present
    expect(job.classifier_attempts).to eq(1)
  end

  it "records timing and outcome for an uncertain classifier result" do
    job = Job.create!(user: user, repository: repository, issue_number: 116)
    stub_agent_text("not json")

    described_class.call(job: job, github_client: github_client)

    attempt = job.reload.classification_attempts.sole
    expect(attempt).to have_attributes(
      started_at: be_present,
      finished_at: be_present,
      outcome: "uncertain"
    )
    expect(attempt.error).to include("invalid JSON")
    expect(attempt.raw_output).to eq("not json")
  end

  it "stores raw classifier output in a larger-than-text column" do
    limit = JobClassificationAttempt.columns_hash.fetch("raw_output").limit

    expect(limit).to be >= 16.megabytes
  end

  it "records timing and outcome for a raised classifier error" do
    job = Job.create!(user: user, repository: repository, issue_number: 117)
    stub_agent_text(JSON.generate(
      "epic_id" => 999_999,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    ))

    described_class.call(job: job, github_client: github_client)

    attempt = job.reload.classification_attempts.sole
    expect(attempt).to have_attributes(
      started_at: be_present,
      finished_at: be_present,
      outcome: "errored"
    )
    expect(attempt.error).to include("classifier returned unknown Epic")
    expect(job.triaging_uncertainty_reason).to include("classifier returned unknown Epic")
  end

  it "attributes a classification spawned process to its Job and attempt" do
    job = Job.create!(user: user, repository: repository, issue_number: 118)
    process = nil
    allow(AgentProviders).to receive(:run_one_shot) do
      process = SpawnedProcess.create!(
        kind: "agent",
        command: "codex",
        hostname: "worker-1",
        started_at: Time.current,
        job: Thread.current[:syrus_current_job]
      )
      Thread.current[:syrus_current_job_classification_attempt]&.update_columns(spawned_process_id: process.id)
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: JSON.generate("epic_id" => nil, "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }),
        session_id: nil,
        spawned_process_id: process.id
      )
    end

    described_class.call(job: job, github_client: github_client)

    expect(process.reload.job).to eq(job)
    expect(job.reload.classification_attempts.sole.spawned_process).to eq(process)
  end

  it "keeps the attempt linked to the classifier process when a provider spawns helper processes" do
    job = Job.create!(user: user, repository: repository, issue_number: 119)
    classifier_process = nil
    helper_process = nil
    allow(AgentProviders).to receive(:run_one_shot) do
      attempt = Thread.current[:syrus_current_job_classification_attempt]
      classifier_process = SpawnedProcess.create!(
        kind: "agent",
        command: "codex",
        hostname: "worker-1",
        started_at: Time.current,
        job: Thread.current[:syrus_current_job]
      )
      attempt&.update_columns(spawned_process_id: classifier_process.id) if attempt&.spawned_process_id.blank?
      helper_process = SpawnedProcess.create!(
        kind: "agent",
        command: "codex transcript export",
        hostname: "worker-1",
        started_at: Time.current,
        job: Thread.current[:syrus_current_job]
      )
      attempt&.update_columns(spawned_process_id: helper_process.id) if attempt&.spawned_process_id.blank?
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: JSON.generate("epic_id" => nil, "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }),
        session_id: nil,
        spawned_process_id: classifier_process.id
      )
    end

    described_class.call(job: job, github_client: github_client)

    expect(job.reload.classification_attempts.sole.spawned_process).to eq(classifier_process)
    expect(job.classification_attempts.sole.spawned_process).not_to eq(helper_process)
  end

  it "records uncertainty on the Job without creating a separate alarm" do
    job = Job.create!(user: user, repository: repository, issue_number: 18)
    stub_agent_text("not json")

    expect { described_class.call(job: job, github_client: github_client) }.not_to raise_error
    expect(job.reload.triaging_reason).to eq("classifier_uncertain")
  end

  it "bounds duplicate tokenization for huge issue bodies" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 16,
      issue_title: "Huge ingest payload",
      issue_body: ("alpha " * 600) + ("tailtoken " * 10_000)
    )
    classifier = described_class.new(job: job, github_client: github_client)

    tokens = classifier.send(:job_text, job)

    expect(tokens.size).to eq(described_class::DUPLICATE_TOKEN_LIMIT)
    expect(tokens).to all(eq("alpha").or(eq("huge")).or(eq("ingest")).or(eq("payload")))
    expect(tokens).not_to include("tailtoken")
  end
end
