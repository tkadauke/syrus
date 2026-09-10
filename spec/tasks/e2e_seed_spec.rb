require "rails_helper"
require "rake"

RSpec.describe "e2e:seed" do
  before(:all) do
    Rails.application.load_tasks
  end

  before do
    Rake::Task["e2e:seed"].reenable
    allow(Rails.env).to receive(:development?).and_return(true)
  end

  it "seeds the demo fixtures and marks the demo epic done without raising" do
    expect { Rake::Task["e2e:seed"].invoke }.not_to raise_error

    demo_repo = Repository.find_by!(owner: "demo", name: "syrus-preview")
    demo_user = User.find_by!(email_address: "demo@syrus.local")
    demo_epic = Epic.find_by!(repository: demo_repo, title: "Preview the operator workflow")
    expect(demo_user).to be_chat_available
    expect(demo_user.chat_provider).to eq("codex")
    expect(demo_epic.state).to eq("done")
    expect(demo_epic.done_at).to be_present
    expect(Feature.find_by!(slug: "coding_mode")).to be_enabled
    coding_chat = demo_user.chat_sessions.find_by!(title: "Coding Mode handoff UI")
    expect(coding_chat).to have_attributes(
      mode: "planning",
      repository: demo_repo,
      coding_checkout_branch: "syrus/e2e-coding-mode",
      coding_checkout_uncommitted: true
    )
    expect(coding_chat.pending_actions.pluck(:action)).to contain_exactly("complete_implement_step", "submit_coding_changes")
  end

  it "is idempotent: running it twice keeps the original done_at" do
    Rake::Task["e2e:seed"].invoke
    demo_repo = Repository.find_by!(owner: "demo", name: "syrus-preview")
    original_done_at = Epic.find_by!(repository: demo_repo, title: "Preview the operator workflow").done_at

    Rake::Task["e2e:seed"].reenable
    Rake::Task["e2e:seed"].invoke

    demo_epic = Epic.find_by!(repository: demo_repo, title: "Preview the operator workflow")
    expect(demo_epic.done_at).to eq(original_done_at)
  end
end
