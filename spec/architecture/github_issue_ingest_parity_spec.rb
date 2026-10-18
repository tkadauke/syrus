require "rails_helper"
require "ostruct"

RSpec.describe "GitHub issue ingestion parity" do
  def issue(labels:)
    OpenStruct.new(
      number: 42,
      state: "open",
      pull_request: nil,
      title: "Label-driven work",
      body: "",
      updated_at: Time.current,
      user: OpenStruct.new(login: "reporter"),
      labels: labels.map { |name| Struct.new(:name, keyword_init: true).new(name: name) }
    )
  end

  it "gives the core poller and github_source the same label-derived attributes" do
    user = Factories.user(github_token: "ghp_test_token")
    core_repository = Factories.repository(user: user, owner: "acme", name: "core-ingest")
    plugin_repository = Factories.repository(user: user, owner: "acme", name: "plugin-ingest")
    github_issue = issue(labels: [
      "syrus",
      Workflows::SKIP_PREPARE_LABEL,
      Workflows::INVESTIGATION_LABEL,
      "syrus-track-hotfix"
    ])
    allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)

    PollRepositoryJob.new.send(
      :ingest,
      github_issue,
      core_repository,
      prior_jobs_by_issue_number: {},
      linked_open_prs: {},
      linked_lookup_numbers: {},
      linked_lookup_overflow_numbers: {}
    )
    plugin_repository.github_input_source.send(:ingest, github_issue)

    expected_attributes = GithubIssueJobAttributes.for_creation(github_issue)
    expect(expected_attributes).to eq(
      skip_prepare: true,
      prepare_skip_reason_override: "issue_label",
      delivery_track: "hotfix",
      investigation: true
    )

    # prepare_skip_reason_override is a creation-only virtual attribute, so
    # compare the persisted outcomes after each ingestion path has consumed it.
    attribute_names = GithubIssueJobAttributes::CREATION_ATTRIBUTE_NAMES - [ "prepare_skip_reason_override" ]
    core_job = core_repository.jobs.sole
    plugin_job = plugin_repository.jobs.sole
    core_attributes = attribute_names.index_with { |name| core_job.public_send(name) }
    plugin_attributes = attribute_names.index_with { |name| plugin_job.public_send(name) }

    expect(plugin_attributes).to eq(core_attributes)
    expect(plugin_attributes).to eq(
      "skip_prepare" => true,
      "delivery_track" => "hotfix",
      "investigation" => true
    )
  end
end
