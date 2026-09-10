namespace :e2e do
  desc "Seed deterministic local fixtures for Playwright E2E specs"
  task seed: :environment do
    unless Rails.env.development? || ENV["ALLOW_E2E_SEED"] == "1"
      abort "e2e:seed only runs in development unless ALLOW_E2E_SEED=1 is set"
    end

    Rails.application.load_seed

    settings = AppSetting.current
    settings.update!(
      mode: "advanced",
      mode_configured_at: nil,
      github_app_id: nil,
      github_app_slug: nil,
      github_app_registered_at: nil
    )

    demo_user = User.find_by!(email_address: "demo@syrus.local")
    demo_epic = Epic.find_by!(repository: Repository.find_by!(owner: "demo", name: "syrus-preview"),
                              title: "Preview the operator workflow")
    demo_epic.update!(state: "done", done_at: demo_epic.done_at || Time.current)

    # e2e/chat.spec.ts drives the demo user's real Chat UI, which gates the
    # whole message stream -- including already-seeded history -- behind
    # User#chat_available? (see ChatView in app/frontend/routes/Chat.tsx).
    # db/seeds.rb intentionally seeds no credentials, so without this the
    # seeded "Preview walkthrough" chat never renders. A fake key is enough:
    # no worker process runs against this preview server, so nothing ever
    # calls out with it.
    demo_user.update!(codex_api_key: "sk-e2e-demo-chat") if demo_user.codex_api_key.blank?

    # Clicking "New Chat" reuses any existing message-less ChatSession
    # instead of creating one (see firstUnstartedChat in
    # app/frontend/lib/unstartedChat.ts). Repeated local runs of this task --
    # or ordinary manual use of this preview -- can leave several behind, so
    # clear them here to keep that click deterministic.
    demo_user.chat_sessions.where(onboarding: false, last_message_at: nil).destroy_all

    onboarding_user = User.find_or_initialize_by(email_address: "onboarding@syrus.local")
    onboarding_user.assign_attributes(
      name: "Onboarding Operator",
      first_name: "Onboarding",
      last_name: "Operator",
      global_role: "admin",
      agent_provider: "codex",
      chat_provider: "codex",
      codex_api_key: nil,
      github_token: nil
    )
    onboarding_user.password = "password" if onboarding_user.new_record? || onboarding_user.password_digest.blank?
    onboarding_user.save!

    Repository.find_by(owner: "e2e", name: "needs-onboarding")&.destroy!
    onboarding_user.chat_sessions.where(onboarding: true).destroy_all
    onboarding_user.epics.find_each(&:destroy!)

    invite_email = "invited-e2e@syrus.local"
    User.find_by(email_address: invite_email)&.destroy!
    Invitation.where(email_address: invite_email).destroy_all
    Invitation.create!(
      email_address: invite_email,
      invited_by: demo_user,
      token: "e2e-invitation-token-0001",
      expires_at: 7.days.from_now
    )
  end
end
