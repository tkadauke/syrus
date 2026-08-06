module AppApi
  class BootstrapSerializer
    def initialize(user:, csrf_token:, default_chat_path:, flash: {})
      @user = user
      @csrf_token = csrf_token
      @default_chat_path = default_chat_path
      @flash = flash
    end

    def as_json(*)
      PerformanceLogging.phase("bootstrap_payload", authenticated: user.present?) do
        {
          current_user: PerformanceLogging.phase("bootstrap.current_user") { user_payload },
          team_user_count: PerformanceLogging.phase("bootstrap.team_user_count") { user ? User.count : 0 },
          app: PerformanceLogging.phase("bootstrap.app") { app_payload },
          setup_status: PerformanceLogging.phase("bootstrap.setup_status") { setup_status_payload },
          provider_availability: PerformanceLogging.phase("bootstrap.provider_availability") { provider_availability_payload },
          public: PerformanceLogging.phase("bootstrap.public") { public_payload },
          navigation: navigation_payload,
          setup: PerformanceLogging.phase("bootstrap.setup") { setup_payload },
          flash: flash_payload,
          system_alerts: PerformanceLogging.phase("bootstrap.system_alerts") { system_alerts_payload },
          unread_notifications_count: PerformanceLogging.phase("bootstrap.unread_notifications_count") { unread_notifications_count },
          csrf_token: @csrf_token,
          feature_flags: PerformanceLogging.phase("bootstrap.feature_flags") { feature_flags_payload }
        }
      end
    end

    private

    attr_reader :user

    def user_payload
      return nil unless user

      {
        id: user.id,
        email_address: user.email_address,
        name: user.name,
        first_name: user.first_name,
        last_name: user.last_name,
        display_name: user.display_name,
        admin: user.admin?,
        role: user.role,
        scheduling_paused: user.scheduling_paused,
        landing_paused: user.landing_paused,
        theme: user.theme,
        locale: user.locale,
        agent_provider: user.agent_provider,
        chat_provider: user.chat_provider,
        agent_max_turns: user.agent_max_turns,
        # Gates the walkthrough-video UI: without a key the composer offers
        # the Gemini setup sheet instead of the recorder/upload.
        gemini_configured: user.gemini_configured?,
        notification_unread_count: user.notifications.unread.count,
        seen_tours: user.seen_tours
      }
    end

    def app_payload
      {
        revision: app_revision,
        revision_url: app_revision_url,
        version: app_version,
        built_at: app_built_at,
        bug_report_mode: user ? BugReports::Router.mode_for(user: user)&.to_s : nil,
        report_issue_repo_slug: AppSetting.report_issue_repo_slug,
        mode: AppSetting.mode,
        mode_configured: AppSetting.mode_configured?
      }
    end

    def setup_status_payload
      return nil unless user

      AppApi::SetupStatus.new(user).as_json
    end

    def provider_availability_payload
      return {} unless user

      ::App::ProviderAvailability.all_for_user(user)
    end

    def public_payload
      {
        first_signup: User.count.zero?,
        signups_open: AppSetting.signups_open?,
        signup_path: "/users/new",
        sign_in_path: "/session/new",
        docs_url: ENV.fetch("SYRUS_DOCS_URL", "https://syrus.dev/docs/getting-started"),
        evaluation_url: ENV.fetch("SYRUS_EVALUATION_URL", "https://syrus.dev/docs/deployment/docker-compose")
      }
    end

    def navigation_payload
      {
        default_chat_path: @default_chat_path
      }
    end

    def setup_payload
      return nil unless user

      ::App::SetupStatus.call(user: user)
    end

    def flash_payload
      {
        alert: @flash[:alert].presence,
        notice: @flash[:notice].presence
      }
    end

    def system_alerts_payload
      SystemAlerts.active_for(user: user).map do |alert|
        {
          id: alert.id,
          dismissal_key: alert.dismissal_key,
          severity: alert.severity.to_s,
          title: alert.title,
          message: alert.message,
          action_steps: alert.action_steps,
          cta: alert.cta,
          actions: alert.actions
        }
      end
    end

    def unread_notifications_count
      return 0 unless user

      if user.respond_to?(:notifications)
        user.notifications.where(read_at: nil).count
      elsif defined?(::Notification)
        ::Notification.where(user: user, read_at: nil).count
      else
        0
      end
    end

    def feature_flags_payload
      Features::SyncFromYaml.declarations.to_h do |feature|
        slug = feature.fetch(:slug)
        [ slug, Feature.enabled?(slug) ]
      end
    end

    def app_revision
      ENV["GIT_SHA"].presence || "dev"
    end

    # The release version baked into published images (bin/publish-image passes
    # --build-arg SYRUS_VERSION=X.Y.Z; the Dockerfile bakes it as ENV). Nil on
    # dev/deploy builds — the BuildBadge then falls back to the git SHA.
    def app_version
      ENV["SYRUS_VERSION"].presence
    end

    # When the running image was built (UTC ISO-8601; SYRUS_BUILT_AT baked the
    # same way as SYRUS_VERSION). Feeds the BuildBadge hover tooltip so a
    # diverged app/backend pair shows which part is older. Nil when absent —
    # the badge simply renders no tooltip.
    def app_built_at
      ENV["SYRUS_BUILT_AT"].presence
    end

    def app_revision_url
      return nil if app_revision == "dev"
      return nil if github_repo.blank?

      "https://github.com/#{github_repo}/commit/#{app_revision}"
    end

    # The build-revision link is cosmetic, so a missing SYRUS_GITHUB_REPO must
    # degrade to "no link" rather than raise — a bare ENV.fetch here 500s every
    # SPA page (this serializer renders on all of them) the moment GIT_SHA is a
    # real commit instead of "dev".
    def github_repo
      ENV["SYRUS_GITHUB_REPO"].presence
    end
  end
end
