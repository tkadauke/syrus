namespace :e2e do
  desc "Seed deterministic local fixtures for Playwright E2E specs"
  task seed: :environment do
    unless Rails.env.development? || ENV["ALLOW_E2E_SEED"] == "1"
      abort "e2e:seed only runs in development unless ALLOW_E2E_SEED=1 is set"
    end

    Rails.application.load_seed

    now = Time.current
    settings = AppSetting.current
    settings.update!(
      mode: "advanced",
      mode_configured_at: settings.mode_configured_at || now,
      github_app_id: settings.github_app_id || 12_345,
      github_app_slug: settings.github_app_slug.presence || "syrus-e2e",
      github_app_registered_at: settings.github_app_registered_at || now
    )

    demo_user = User.find_by!(email_address: "demo@syrus.local")
    demo_epic = Epic.find_by!(repository: Repository.find_by!(owner: "demo", name: "syrus-preview"),
                              title: "Preview the operator workflow")
    demo_epic.update!(state: "done", done_at: demo_epic.done_at || now)

    onboarding_user = User.find_or_initialize_by(email_address: "onboarding@syrus.local")
    onboarding_user.assign_attributes(
      name: "Onboarding Operator",
      first_name: "Onboarding",
      last_name: "Operator",
      global_role: "admin",
      agent_provider: "codex",
      chat_provider: "codex",
      codex_api_key: "sk-e2e-onboarding",
      github_token: "ghp_e2e_onboarding"
    )
    onboarding_user.password = "password" if onboarding_user.new_record? || onboarding_user.password_digest.blank?
    onboarding_user.save!

    onboarding_repo = Repository.find_or_initialize_by(owner: "e2e", name: "needs-onboarding")
    onboarding_repo.assign_attributes(
      user: onboarding_user,
      default_branch: "main",
      trigger_label: "syrus",
      polling_enabled: false,
      prepare_enabled: true,
      agent_provider: "codex",
      review_policy: "self",
      feedback_policy: "confirm",
      epic_dependency_policy: "linear"
    )
    onboarding_repo.save!

    onboarding_user.chat_sessions.where(onboarding: true).destroy_all
    onboarding_user.epics.find_each { |epic| epic.update!(state: "backlog", done_at: nil) }

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
