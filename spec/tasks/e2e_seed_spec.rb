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
