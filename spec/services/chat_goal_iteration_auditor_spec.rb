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
end
