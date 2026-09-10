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
    Feature.find_or_create_by!(slug: "coding_mode") do |feature|
      feature.category = "Labs"
      feature.name = "Coding Mode"
      feature.description = "Enables Coding Mode for Syrus Chat."
      feature.default_enabled = true
    end.update!(enabled: true)

    demo_user = User.find_by!(email_address: "demo@syrus.local")
    demo_user.update!(
      agent_provider: "codex",
      chat_provider: "codex",
      codex_api_key: "sk-e2e-codex",
      landing_paused: false
    )
    demo_epic = Epic.find_by!(repository: Repository.find_by!(owner: "demo", name: "syrus-preview"),
                              title: "Preview the operator workflow")
    demo_epic.update!(state: "done", done_at: demo_epic.done_at || Time.current)
    demo_repo = demo_epic.repository

    coding_chat = ChatSession.find_or_initialize_by(user: demo_user, title: "Coding Mode handoff UI")
    coding_chat.assign_attributes(
      repository: demo_repo,
      mode: "planning",
      pinned: true,
      last_message_at: Time.current,
      coding_checkout_branch: "syrus/e2e-coding-mode",
      coding_checkout_prepare_status: "succeeded",
      coding_checkout_prepare_finished_at: Time.current,
      coding_checkout_uncommitted: true
    )
    coding_chat.save!
    if coding_chat.messages.none?
      coding_chat.messages.create!(
        role: "assistant",
        content: { "text" => "Coding Mode is ready to review the writable checkout state and handoff confirmations." }
      )
    end

    coding_job = Job.find_or_initialize_by(repository: demo_repo, issue_title: "E2E Coding Mode existing Job handoff")
    coding_job.assign_attributes(
      user: demo_user,
      owner_user: demo_user,
      kind: "direct",
      issue_number: nil,
      issue_body: "Seeded existing Job for Coding Mode handoff UI coverage.",
      state: "coding",
      branch_name: "syrus/e2e-existing-job-handoff",
      pr_number: 105,
      linked_chat_id: coding_chat.id,
      agent_provider: "codex",
      priority: "medium",
      credential_mode: demo_repo.credential_mode || "app",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending"
    )
    coding_job.save!

    coding_chat.pending_actions.where(action: %w[complete_implement_step submit_coding_changes]).destroy_all
    coding_chat.pending_actions.create!(
      action: "complete_implement_step",
      requested_by: "agent",
      repository: demo_repo,
      payload: { "job_id" => coding_job.id }
    )
    coding_chat.pending_actions.create!(
      action: "submit_coding_changes",
      requested_by: "agent",
      repository: demo_repo,
      payload: {
        "repository_id" => demo_repo.id,
        "branch" => "syrus/e2e-coding-mode",
        "title" => "E2E Coding Mode submitted changes",
        "description" => "Seeded chat-authored work waiting for operator handoff confirmation."
      }
    )

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
