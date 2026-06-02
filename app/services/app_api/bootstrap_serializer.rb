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
        app: app_payload,
        navigation: navigation_payload,
        setup: setup_payload,
        flash: flash_payload,
        csrf_token: @csrf_token,
        feature_flags: {
          migrated_routes: []
        }
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
        display_name: user.display_name,
        admin: user.admin?,
        scheduling_paused: user.scheduling_paused,
        landing_paused: user.landing_paused,
        agent_provider: user.agent_provider,
        agent_max_turns: user.agent_max_turns
      }
    end

    def app_payload
      {
        revision: app_revision,
        revision_url: app_revision_url
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

    def app_revision
      ENV["GIT_SHA"].presence || "dev"
    end

    def app_revision_url
      return nil if app_revision == "dev"

      "https://github.com/#{github_repo}/commit/#{app_revision}"
    end

    def github_repo
      ENV.fetch("SYRUS_GITHUB_REPO")
    end
  end
end
