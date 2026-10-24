require "rails_helper"

RSpec.describe AttentionReport::Report do
  let(:user) { Factories.user(github_handle: "Ada") }
  let(:other_user) { Factories.user(github_handle: "Grace") }
  let(:repository) { Factories.repository(user: user) }

  it "classifies explicit deciding, judging, and wasted rules for only the requested user" do
    Factories.job_record(user: user, repository: repository, kind: "direct", issue_number: nil)
    Factories.job_record(user: other_user, repository: Factories.repository(user: other_user), kind: "direct", issue_number: nil)
    job = Factories.job_record(user: user, repository: repository)
    JobApproval.create!(job: job, user: user)
    JobApproval.create!(job: Factories.job_record(user: other_user), user: other_user)
    PrReviewComment.create!(job: job, pr_type: "direct", comment_kind: "review", github_comment_id: 12,
      github_handle: "ADA", comment_created_at: Time.current)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "retry", agent_provider: job.agent_provider)
    StateTransition.create!(subject: job, user: user, source: "operator", from_state: "failed", to_state: "queued", created_at: workflow.created_at)
    job.update!(landing_blocker_override_requested_by_user_id: user.id, landing_blocker_override_requested_at: Time.current)

    payload = described_class.new(user: user, window_days: 7).as_json

    expect(payload.dig(:attention, :deciding, :figures, :human_created_jobs, :count)).to eq(2)
    expect(payload.dig(:attention, :judging, :figures, :job_approvals, :count)).to eq(1)
    expect(payload.dig(:attention, :judging, :figures, :pr_review_comments, :count)).to eq(1)
    expect(payload.dig(:attention, :wasted, :rules, :human_retry_rebase_ci_repair_reruns, :count)).to eq(1)
    expect(payload.dig(:attention, :wasted, :rules, :landing_blocker_overrides, :count)).to eq(1)
    expect(payload.dig(:machine_time, :included_in_attention)).to be(false)
  end

  it "classifies landing rechecks and re-approval after a patch-preserving rebase separately" do
    job = Factories.job_record(user: user, repository: repository)
    first = StateTransition.create!(subject: job, user: user, source: "operator", event_name: "approve",
      from_state: "implemented", to_state: "approved", created_at: 3.hours.ago)
    Workflow.create!(job: job, user: user, trigger_kind: "rebase", agent_provider: job.agent_provider, created_at: 2.hours.ago)
    StateTransition.create!(subject: job, user: user, source: "operator", event_name: "approve",
      from_state: "implemented", to_state: "approved", created_at: 1.hour.ago)
    StateTransition.create!(subject: job, user: user, source: "operator", event_name: "recheck",
      from_state: "landing", to_state: "landing", metadata: { "reason_key" => "landing_blocker_recheck" })

    rules = described_class.new(user: user, window_days: 7).as_json.dig(:attention, :wasted, :rules)

    expect(first.event_name).to eq("approve")
    expect(rules.dig(:landing_blocker_rechecks_and_wakes, :count)).to eq(1)
    expect(rules.dig(:reapproval_after_base_change_unchanged_diff, :count)).to eq(1)
  end

  it "counts user messages between the prior and newly confirmed proposal" do
    chat = ChatSession.create!(user: user, repository: repository)
    first = ChatProposal.create!(chat_session: chat, repository: repository, slug: "first", title: "First", body: "Body", confirmed_at: 10.minutes.ago, state: "confirmed")
    ChatMessage.create!(chat_session: chat, sender_user: user, role: "user", content: { "text" => "one" }, created_at: 9.minutes.ago)
    ChatMessage.create!(chat_session: chat, sender_user: other_user, role: "user", content: { "text" => "other" }, created_at: 8.minutes.ago)
    ChatProposal.create!(chat_session: chat, repository: repository, slug: "second", title: "Second", body: "Body", confirmed_at: 7.minutes.ago, state: "confirmed")

    count = described_class.new(user: user, window_days: 7).as_json
      .dig(:attention, :deciding, :figures, :messages_before_confirmed_proposals, :count)

    expect(first).to be_confirmed
    expect(count).to eq(1)
  end

  it "reports telemetry off distinctly" do
    AppSetting.current.update!(ui_engagement_telemetry_enabled: false)
    expect(described_class.new(user: user, window_days: 7).as_json[:page_time]).to eq(
      telemetry_state: "off", by_page_type: {}
    )
  end
end
