require "rails_helper"
require "ostruct"

RSpec.describe Jobs::PreemptedExternalPrBackfill do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }

  def preempted_job(external_pr_number:)
    Job.create!(
      user: user,
      repository: repository,
      issue_number: external_pr_number,
      state: "closed",
      closure_reason: "preempted",
      external_pr_number: external_pr_number,
      finished_at: Time.current
    )
  end

  def service_for(responses)
    client = double("GithubClient")
    allow(client).to receive(:pull_request) do |_slug, number, bypass_cache:|
      expect(bypass_cache).to be true
      response = responses.fetch(number)
      raise response if response.is_a?(Exception)

      response
    end

    described_class.new(client_factory: ->(_job) { client }, logger: logger)
  end

  it "reopens preempted issue Jobs whose external PR is still open" do
    job = preempted_job(external_pr_number: 9)
    service = service_for(9 => OpenStruct.new(state: "open", merged: false))

    result = service.call

    expect(result.checked).to eq(1)
    expect(result.reopened).to eq(1)
    expect(job.reload).to be_implemented
    expect(job.closure_reason).to be_nil
    expect(job.finished_at).to be_nil
  end

  it "skips preempted Jobs when the external PR is already merged or closed" do
    merged = preempted_job(external_pr_number: 9)
    closed = preempted_job(external_pr_number: 10)
    service = service_for(
      9 => OpenStruct.new(state: "closed", merged: true),
      10 => OpenStruct.new(state: "closed", merged: false)
    )

    result = service.call

    expect(result.checked).to eq(2)
    expect(result.reopened).to eq(0)
    expect(result.skipped).to eq(2)
    expect(merged.reload).to be_closed
    expect(closed.reload).to be_closed
  end

  it "does not touch non-issue or non-preempted Jobs" do
    issue = preempted_job(external_pr_number: 9)
    Job.create!(user: user, repository: repository, kind: "external_pr", external_pr_number: 10, state: "implemented")
    Job.create!(user: user, repository: repository, issue_number: 11, state: "closed", closure_reason: "manual", external_pr_number: 11, finished_at: Time.current)
    service = service_for(9 => OpenStruct.new(state: "open", merged: false))

    result = service.call

    expect(result.checked).to eq(1)
    expect(issue.reload).to be_implemented
  end

  it "supports dry runs without reopening the Job" do
    job = preempted_job(external_pr_number: 9)
    service = service_for(9 => OpenStruct.new(state: "open", merged: false))

    result = service.call(dry_run: true)

    expect(result.reopened).to eq(1)
    expect(job.reload).to be_closed
  end
end
