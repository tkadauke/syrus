require "rails_helper"

RSpec.describe ChatGoalIterationAuditor, type: :service do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  it "audits goal continuations nested inside a batched internal notice message" do
    goal = ChatGoal.create!(
      chat_session: chat,
      user: user,
      repository: repository,
      prompt: "Keep implementing",
      mode_snapshot: { "mode" => "coding", "repository_id" => repository.id }
    )
    message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Goal continuation started.\n\nProposal confirmed. JOB-716 was created.",
        "source" => "queued_internal_notice_batch",
        "notices" => [
          {
            "queued_message_id" => 1,
            "text" => "Goal continuation started.",
            "source" => "goal_continuation",
            "content" => {
              "text" => "Goal continuation started.",
              "internal_prompt" => "Continue with private goal context.",
              "source" => "goal_continuation",
              "goal_continuation" => true,
              "chat_goal_id" => goal.id,
              "iteration" => 1
            }
          },
          {
            "queued_message_id" => 2,
            "text" => "Proposal confirmed. JOB-716 was created.",
            "source" => "proposal_notification",
            "content" => {
              "text" => "Proposal confirmed. JOB-716 was created.",
              "source" => "proposal_notification",
              "outcome" => "confirmed",
              "acknowledgment" => "Confirmed JOB-716."
            }
          }
        ]
      }
    )

    described_class.after_turn!(chat_session: chat, user_message: message)

    expect(goal.reload.consecutive_no_op_iterations).to eq(1)
    expect(goal.last_iteration_signature).to eq("goal:#{goal.id}:empty")
  end

  it "blocks after three wakeups whose continuation turns create no goal work" do
    goal = ChatGoal.create!(
      chat_session: chat,
      user: user,
      repository: repository,
      prompt: "Keep implementing",
      mode_snapshot: { "mode" => "coding", "repository_id" => repository.id }
    )
    job = Factories.job_record(
      user: user,
      repository: repository,
      chat_goal: goal,
      state: "queued",
      issue_number: 12
    )
    state_changes = [
      [ { state: "implemented" }, :publish_goal_implemented_event ],
      [ { state: "approved" }, :publish_goal_approved_event ],
      [ { state: "closed", closure_reason: "pr_merged" }, :publish_goal_closed_event ]
    ]
    signatures = []
    base_time = Time.current

    state_changes.each_with_index do |(attributes, publish_event), index|
      travel_to(base_time + index + 1) do
        job.update!(attributes)
        job.send(publish_event)
        message = chat.chat_queued_messages.order(:id).last

        described_class.after_turn!(chat_session: chat, user_message: message)
        signatures << goal.reload.last_iteration_signature
        chat.update!(turn_in_flight: false)
      end
    end

    expect(signatures.uniq.size).to eq(ChatGoal::MAX_CONSECUTIVE_NO_OP_ITERATIONS)
    expect(goal.reload).to have_attributes(
      status: "blocked",
      terminal_reason: "max_consecutive_no_op_iterations",
      consecutive_no_op_iterations: ChatGoal::MAX_CONSECUTIVE_NO_OP_ITERATIONS,
      last_iteration_signature: signatures.last
    )
    expect(chat.messages.order(:id).last.content["text"]).to eq(
      "Goal blocked after 3 continuation turns made no provenance-linked progress."
    )
  end

  it "resets consecutive no-op iterations when a continuation creates goal work" do
    goal = ChatGoal.create!(
      chat_session: chat,
      user: user,
      repository: repository,
      prompt: "Keep implementing",
      mode_snapshot: { "mode" => "coding", "repository_id" => repository.id }
    )
    goal.update!(
      consecutive_no_op_iterations: 2,
      last_iteration_signature: "goal:#{goal.id}:empty"
    )
    message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Goal continuation started.",
        "source" => "goal_continuation",
        "goal_continuation" => true,
        "chat_goal_id" => goal.id
      }
    )
    Factories.job_record(user: user, repository: repository, chat_goal: goal)

    described_class.after_turn!(chat_session: chat, user_message: message)

    expect(goal.reload.consecutive_no_op_iterations).to eq(0)
    expect(goal.last_iteration_signature).to be_present
  end
end
