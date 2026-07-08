require "rails_helper"

RSpec.describe App::SetupStatus do
  it "points a new first user at credentials" do
    user = Factories.user

    payload = described_class.call(user: user)

    expect(payload[:complete]).to eq(false)
    expect(payload[:next_step]).to eq("credentials")
    expect(payload.dig(:credentials, :ready)).to eq(false)
    expect(payload.dig(:system, :ready)).to eq(true)
    expect(payload.dig(:repositories, :active_count)).to eq(0)
    expect(payload.dig(:progress, :completed)).to eq(0)
  end

  it "advances through repository and chat states until the first Epic lands" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
    user = Factories.user(github_token: "ghp_test", claude_oauth_token: "oat-test")
    expect(described_class.call(user: user)[:next_step]).to eq("repository")

    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    repository_payload = described_class.call(user: user)
    expect(repository_payload[:next_step]).to eq("chat")
    expect(repository_payload.dig(:repositories, :first, :slug)).to eq("acme/widgets")
    expect(repository_payload.dig(:repositories, :first, :credential_mode)).to eq("pat")

    # An Epic that has not landed yet keeps the chat step open.
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    in_progress_payload = described_class.call(user: user)
    expect(in_progress_payload[:complete]).to eq(false)
    expect(in_progress_payload[:next_step]).to eq("chat")

    epic.update!(state: "done")
    complete_payload = described_class.call(user: user)
    expect(complete_payload[:complete]).to eq(true)
    expect(complete_payload[:next_step]).to eq("complete")
    expect(complete_payload.dig(:progress, :completed)).to eq(3)
  end

  it "stays complete after the landed first Epic is archived" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
    user = Factories.user(github_token: "ghp_test", claude_oauth_token: "oat-test")
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    epic.override_state!("done")
    expect(described_class.call(user: user)[:complete]).to eq(true)

    epic.override_state!("archived")
    archived_payload = described_class.call(user: user)
    expect(archived_payload[:complete]).to eq(true)
    expect(archived_payload[:next_step]).to eq("complete")
  end

  it "does not complete for a fresh user whose only Epic was archived without landing" do
    user = Factories.user
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "backlog")
    epic.archive!

    expect(described_class.call(user: user)[:complete]).to eq(false)
  end

  it "completes for a user whose owned (but not created) Epic landed" do
    creator = Factories.user
    owner = Factories.user
    repository = Factories.repository(user: creator)
    Factories.epic(user: creator, repository: repository, state: "done", owner_user: owner)

    expect(described_class.call(user: owner)[:complete]).to eq(true)
  end

  it "reports chat_started and the onboarding chat path once the chat begins" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
    user = Factories.user(github_token: "ghp_test", claude_oauth_token: "oat-test")
    repository = Factories.repository(user: user)

    before = described_class.call(user: user)
    expect(before[:chat_started]).to eq(false)
    expect(before[:onboarding_chat_path]).to be_nil
    expect(before[:next_step]).to eq("chat")

    chat = ChatSession.create!(user: user, repository: repository, onboarding: true)
    after = described_class.call(user: user)
    expect(after[:chat_started]).to eq(true)
    expect(after[:onboarding_chat_path]).to eq("/chats/#{chat.id}")
    expect(after[:next_step]).to eq("epic")
    expect(after[:complete]).to eq(false)
  end

  it "requires both a registered GitHub App and a personal access token" do
    AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
    user = Factories.user(github_token: nil, claude_oauth_token: "oat-test")

    # App alone is not enough — credentials stay incomplete.
    app_only = described_class.call(user: user)
    expect(app_only.dig(:credentials, :ready)).to eq(false)
    expect(app_only.dig(:credentials, :github_app)).to eq(true)
    expect(app_only.dig(:credentials, :github_token)).to eq(false)
    expect(app_only[:next_step]).to eq("credentials")

    # Adding the token completes the credentials step.
    user.update!(github_token: "ghp_test")
    both = described_class.call(user: user)
    expect(both.dig(:credentials, :ready)).to eq(true)
    expect(both[:next_step]).to eq("repository")
    credentials_step = both.dig(:progress, :steps).find { |step| step[:key] == "credentials" }
    expect(credentials_step).to include(complete: true)
  end
end
