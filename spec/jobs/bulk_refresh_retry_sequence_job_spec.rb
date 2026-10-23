require "rails_helper"

RSpec.describe BulkRefreshRetrySequenceJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def failed_source(job)
    Workflow.create!(job: job, trigger_kind: "initial", state: "failed",
      started_at: 10.minutes.ago, finished_at: 1.minute.ago)
  end

  def member(job:, source:, upstream_ids: [])
    {
      action: "retry_job",
      payload: {
        "job_id" => job.id,
        "mode" => "refresh_base",
        "source_workflow_id" => source.id,
        "reason" => "The effective base was repaired.",
        "selected_upstream_job_ids" => upstream_ids
      }
    }
  end

  def result(workflow)
    BaseRefreshRetryEnqueuer::Result.new(workflow: workflow, checkpoint: nil, error: nil, launch_result: nil)
  end

  it "waits for an upstream refresh to succeed before starting its dependent" do
    upstream = Factories.job_record(user: user, repository: repository, state: "failed")
    dependent = Factories.job_record(user: user, repository: repository, state: "failed", issue_number: 43)
    upstream_source = failed_source(upstream)
    dependent_source = failed_source(dependent)
    upstream_refresh = Workflow.create!(job: upstream, trigger_kind: "base_refresh_retry", state: "running")
    dependent_refresh = Workflow.create!(job: dependent, trigger_kind: "base_refresh_retry", state: "queued")
    group = PendingActionGroup.create_with_members!(chat_session: chat_session, member_attributes: [
      member(job: upstream, source: upstream_source),
      member(job: dependent, source: dependent_source, upstream_ids: [ upstream.id ])
    ])
    allow(BaseRefreshRetryEnqueuer).to receive(:call)
      .with(job: upstream, source_workflow: upstream_source, reason: "The effective base was repaired.")
      .and_return(result(upstream_refresh))
    allow(BaseRefreshRetryEnqueuer).to receive(:call)
      .with(job: dependent, source_workflow: dependent_source, reason: "The effective base was repaired.")
      .and_return(result(dependent_refresh))

    group.confirm_all!(user: user)
    expect(group.reload.confirmation_notice).to eq("Queued 2 pending actions for dependency-aware execution.")
    described_class.perform_now(group.id)
    described_class.perform_now(group.id)

    actions = group.chat_pending_actions.order(:id).to_a
    expect(actions.first.reload).to be_confirming
    expect(actions.first.result).to eq(upstream_refresh)
    expect(actions.second.reload).to be_confirming
    expect(actions.second.result).to be_nil
    expect(BaseRefreshRetryEnqueuer).not_to have_received(:call).with(
      job: dependent, source_workflow: dependent_source, reason: "The effective base was repaired."
    )
    expect(BaseRefreshRetryEnqueuer).to have_received(:call).with(
      job: upstream, source_workflow: upstream_source, reason: "The effective base was repaired."
    ).once

    upstream_refresh.update!(state: "succeeded", finished_at: Time.current)
    described_class.perform_now(group.id)

    expect(actions.first.reload).to be_confirmed
    expect(actions.second.reload).to be_confirming
    expect(actions.second.result).to eq(dependent_refresh)
  end

  it "fails a dependent clearly without starting it when its upstream refresh fails" do
    upstream = Factories.job_record(user: user, repository: repository, state: "failed")
    dependent = Factories.job_record(user: user, repository: repository, state: "failed", issue_number: 43)
    upstream_source = failed_source(upstream)
    dependent_source = failed_source(dependent)
    upstream_refresh = Workflow.create!(job: upstream, trigger_kind: "base_refresh_retry", state: "running")
    group = PendingActionGroup.create_with_members!(chat_session: chat_session, member_attributes: [
      member(job: upstream, source: upstream_source),
      member(job: dependent, source: dependent_source, upstream_ids: [ upstream.id ])
    ])
    allow(BaseRefreshRetryEnqueuer).to receive(:call)
      .with(job: upstream, source_workflow: upstream_source, reason: "The effective base was repaired.")
      .and_return(result(upstream_refresh))

    group.confirm_all!(user: user)
    described_class.perform_now(group.id)
    upstream_refresh.update!(state: "failed", finished_at: Time.current)
    described_class.perform_now(group.id)

    actions = group.chat_pending_actions.order(:id).to_a
    expect(actions.first.reload).to be_failed
    expect(actions.first.execution_error).to include("ended failed")
    expect(actions.second.reload).to be_failed
    expect(actions.second.execution_error).to include("Selected upstream refresh failed")
    expect(BaseRefreshRetryEnqueuer).to have_received(:call).once
    expect(group.reload).to be_confirmed
  end
end
