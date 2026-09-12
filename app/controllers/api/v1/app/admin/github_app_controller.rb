module Api
  module V1
    module App
      module Admin
        class GithubAppController < BaseController
          def register
            state = GithubAppManifestState.generate(user: Current.user, origin: params[:origin].to_s.presence)

            # The registration itself happens in the user's default browser via
            # the tokenized bounce page — never in an embedded window, where the
            # user typically has no GitHub login. `syrus_external=1` tells the
            # desktop shell to hand the URL to the OS browser.
            render json: status_payload.merge(
              bounce_url: admin_github_app_manifest_url(state: state, syrus_external: 1),
              submit_label: AppSetting.github_app_registered? ? I18n.t("api.admin_github_app.reregister") : I18n.t("api.admin_github_app.register")
            )
          end

          def confirm
            render json: status_payload
          end

          # Syrus is poll-based (no webhooks), so a fresh App installation is
          # normally only discovered by the recurring 5-minute sync. The setup
          # UIs call this while the operator is on GitHub's install page so
          # detection takes seconds instead. Cache-throttled: hammering it
          # from a 3s poll enqueues at most one sync per window. 5s is far
          # from GitHub's app-auth rate limits (one installations-list call
          # per sync) — the throttle exists to keep the queue tidy, and it is
          # the detection-latency floor, so keep it short.
          SYNC_THROTTLE = 5.seconds

          def sync_installations
            enqueued = Rails.cache.write("github_app_sync_installations_throttle", 1, unless_exist: true, expires_in: SYNC_THROTTLE)
            SyncInstallationsJob.perform_later(Current.user.id) if enqueued
            render json: { enqueued: !!enqueued }
          end

          private

          def status_payload
            setting = AppSetting.current

            {
              github_app: {
                registered: setting.github_app_registered?,
                id: setting.github_app_id,
                slug: setting.github_app_slug,
                registered_at: setting.github_app_registered_at&.iso8601,
                install_url: ::App::Presentation.github_app_generic_install_url,
                # Lets the setup UI flip to "installed on <account>" the
                # moment a sync links the installation.
                installations: Installation.active.order(:account_login).map do |installation|
                  { account_login: installation.account_login, account_type: installation.account_type }
                end
              }
            }
          end
        end
      end
    end
  end
end
