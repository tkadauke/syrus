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
    creation_arguments = []
    allow(Job).to receive(:create!).and_wrap_original do |method, *args, **keywords, &block|
      attributes = keywords.presence || args.first
      creation_arguments << attributes.dup
      method.call(*args, **keywords, &block)
    end
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

    expect(creation_arguments.size).to eq(2)
    core_arguments, plugin_arguments = creation_arguments
    path_specific_attributes = %i[
      repository
      input_source
      external_ref
      linked_open_pr_checked_at
    ]

    expect(plugin_arguments.except(*path_specific_attributes)).to eq(
      core_arguments.except(*path_specific_attributes)
    )
    expect(core_arguments.slice(*GithubIssueJobAttributes::CREATION_ATTRIBUTE_NAMES.map(&:to_sym))).to eq(
      skip_prepare: true,
      prepare_skip_reason_override: "issue_label",
      delivery_track: "hotfix",
      investigation: true
    )
  end
end
