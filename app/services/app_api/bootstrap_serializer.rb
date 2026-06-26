module AppApi
  class BootstrapSerializer
    def initialize(user:, csrf_token:, default_chat_path:, flash: {})
      @user = user
      @csrf_token = csrf_token
      @default_chat_path = default_chat_path
      @flash = flash
    end

    def as_json(*)
      {
        current_user: user_payload,
        team_user_count: user ? User.count : 0,
        app: app_payload,
        setup_status: setup_status_payload,
        public: public_payload,
        navigation: navigation_payload,
        setup: setup_payload,
        flash: flash_payload,
        system_alerts: system_alerts_payload,
        unread_notifications_count: unread_notifications_count,
        csrf_token: @csrf_token,
        feature_flags: feature_flags_payload
      }
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
        scheduling_paused: user.scheduling_paused,
        landing_paused: user.landing_paused,
        theme: user.theme,
        agent_provider: user.agent_provider,
        agent_max_turns: user.agent_max_turns,
        notification_unread_count: user.notifications.unread.count
      }
    end

    def app_payload
      {
        revision: app_revision,
        revision_url: app_revision_url
      }
    end

    def setup_status_payload
      return nil unless user

      AppApi::SetupStatus.new(user).as_json
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
          severity: alert.severity.to_s,
          title: alert.title,
          message: alert.message,
          action_steps: alert.action_steps,
          cta: alert.cta
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
