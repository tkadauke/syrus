require "rails_helper"

RSpec.describe "Backend locale keys", type: :unit do
  # Spot-check that every key used in mailers, controllers, and flash messages
  # is present in all three supported locales and resolves without MissingTranslation.
  let(:required_keys) do
    %w[
      passwords_mailer.reset.subject
      invitation_mailer.invite.subject
      passwords_mailer.reset.intro
      passwords_mailer.reset.link_text
      passwords_mailer.reset.expires
      invitation_mailer.invite.invited
      invitation_mailer.invite.accept_intro
      invitation_mailer.invite.accept_link
      invitation_mailer.invite.expires
      sessions.rate_limited
      sessions.invalid_credentials
      passwords.rate_limited
      passwords.reset_sent
      passwords.reset_success
      passwords.mismatch
      passwords.token_invalid
      users.signup_invitation_only
      users.welcome_admin
      users.welcome
      application.admin_required
      api.base.unauthorized
      api.base.admin_required
      api.base.sign_in_required
      api.base.admin_forbidden
      api.auth.invalid_credentials
      api.auth.password_reset_sent
      api.auth.password_reset_success
      api.auth.password_mismatch
      api.auth.token_invalid
      api.auth.signup_closed
      api.auth.welcome_admin
      api.auth.welcome
      api.repositories.already_in_workspace
      api.repositories.added
      api.repositories.updated
      api.repositories.comment_blank
      api.repositories.comment_added
      api.repositories.comment_failed
      api.repositories.issue_closed
      api.repositories.issue_close_failed
      api.repositories.issue_delegated
      api.repositories.issue_delegate_failed
      api.repositories.select_issue
      api.repositories.choose_action
      api.repositories.archived_first
      api.repositories.archived
      api.repositories.unarchived
      api.repositories.no_failed_jobs
      api.repositories.developer_required
      api.repositories.not_triage
      api.repositories.polling
      api.repositories.released_triage
      api.repositories.no_github_token
      api.repositories.github_error
      api.repositories.circuit_open
      api.repositories.circuit_open_until
      api.repositories.bulk_delegate_failed
      api.repositories.bulk_close_failed
      api.job_pins.pinned
      api.job_pins.unpinned
      api.tags.created
      api.tags.updated
      api.tags.deleted
      api.epics.created
      api.epics.updated
      api.epics.archived_already
      api.epics.archived
      api.epics.claimed
      api.epics.unclaimed
      api.epics.reassigned
      api.epics.dependency_added
      api.epics.dependency_removed
      api.epics.not_claimed
      api.epics.unclaim_forbidden
      api.epics.another_user
      api.epics.already_claimed_by_you
      api.epics.already_claimed
      api.epics.ownership_changed_unclaimed
      api.epics.ownership_changed
      api.epics.unknown_state
      api.epics.transition_not_allowed
      api.epics.product_owner_forbidden
      api.epics.access_forbidden
      api.epics.owner_not_found
      api.epics.already_assigned
      api.epics.admin_forbidden
      api.admin_queue.reap_ran
      api.admin_features.not_found
      api.admin_invitations.created
      api.admin_invitations.revoked
      api.admin_settings.updated
      api.admin_settings.unknown_secret
      api.admin_settings.secret_cleared
      api.direct_jobs.repository_not_found
      api.direct_jobs.prompt_blank
      api.direct_jobs.agent_not_configured
      api.direct_jobs.invalid_priority
      api.direct_jobs.epic_not_found
      api.direct_jobs.owner_not_found
      api.direct_jobs.created
      api.admin_workflows.not_failed
      api.admin_workflows.workspace_cleaned_up
      api.admin_workflows.no_failed_step
      api.admin_transcripts.no_session
    ]
  end

  let(:pluralized_keys) do
    %w[
      api.repositories.retry_enqueued
      api.repositories.bulk_delegated
      api.repositories.bulk_closed
    ]
  end

  %i[en de la].each do |locale|
    context "locale: #{locale}" do
      it "has all required string keys" do
        missing = required_keys.reject do |key|
          I18n.t(key, locale: locale).present?
        rescue I18n::MissingTranslationData
          false
        end

        expect(missing).to be_empty, "Missing #{locale} translation keys: #{missing.join(', ')}"
      end

      it "has all required pluralized keys" do
        extra = { provider: "Claude", error: "test" }
        missing = pluralized_keys.reject do |key|
          I18n.t(key, locale: locale, count: 1, **extra).present? &&
            I18n.t(key, locale: locale, count: 2, **extra).present?
        rescue I18n::MissingTranslationData
          false
        end

        expect(missing).to be_empty, "Missing #{locale} pluralized keys: #{missing.join(', ')}"
      end
    end
  end

  it "interpolates variables correctly" do
    expect(I18n.t("api.repositories.added", slug: "owner/repo")).to eq("Repository owner/repo added.")
    expect(I18n.t("api.repositories.comment_added", number: 42)).to eq("Comment added to #42.")
    expect(I18n.t("api.admin_invitations.created", email: "user@example.com")).to eq("Invitation created for user@example.com.")
    expect(I18n.t("api.epics.already_claimed", email: "other@example.com")).to eq("Epic is already claimed by other@example.com.")
    expect(I18n.t("api.admin_workflows.not_failed", slug: "WF-1", state: "succeeded")).to eq("WF-1 is `succeeded`, not `failed`.")
    expect(I18n.t("passwords_mailer.reset.expires", time: "2 hours")).to eq("This link will expire in 2 hours.")
    expect(I18n.t("invitation_mailer.invite.invited", inviter: "Ada Lovelace")).to eq("Ada Lovelace invited you to join Syrus.")
    expect(I18n.t("passwords_mailer.reset.subject")).to eq("Reset your password")
    expect(I18n.t("invitation_mailer.invite.subject")).to eq("You're invited to Syrus")
  end

  it "pluralizes repository retry messages correctly" do
    expect(I18n.t("api.repositories.retry_enqueued", count: 1, provider: "Claude")).to eq("Retry enqueued for 1 failed job with Claude.")
    expect(I18n.t("api.repositories.retry_enqueued", count: 3, provider: "Claude")).to eq("Retry enqueued for 3 failed jobs with Claude.")
    expect(I18n.t("api.repositories.bulk_delegated", count: 1)).to eq("1 issue delegated to Syrus.")
    expect(I18n.t("api.repositories.bulk_delegated", count: 5)).to eq("5 issues delegated to Syrus.")
    expect(I18n.t("api.repositories.bulk_closed", count: 1)).to eq("1 issue closed.")
    expect(I18n.t("api.repositories.bulk_closed", count: 3)).to eq("3 issues closed.")
  end
end
