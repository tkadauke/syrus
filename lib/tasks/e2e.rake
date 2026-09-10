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
