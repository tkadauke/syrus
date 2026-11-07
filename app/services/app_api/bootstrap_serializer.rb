module AppApi
  class BootstrapSerializer
    def initialize(user:, csrf_token:, flash: {})
      @user = user
      @csrf_token = csrf_token
      @flash = flash
    end

    def as_json(*)
      PerformanceLogging.phase("bootstrap_payload", authenticated: user.present?) do
        payload = {
          current_user: PerformanceLogging.phase("bootstrap.current_user") { me_payload[:current_user] },
          time_zones: time_zones_payload,
          team_user_count: PerformanceLogging.phase("bootstrap.team_user_count") { user ? me_payload[:team_user_count] : 0 },
          app: PerformanceLogging.phase("bootstrap.app") { app_payload },
          chat_capabilities: PerformanceLogging.phase("bootstrap.chat_capabilities") { chat_capabilities_payload },
          setup: PerformanceLogging.phase("bootstrap.setup") { setup_payload },
          system_alerts: PerformanceLogging.phase("bootstrap.system_alerts") { system_alerts_payload },
          unread_notifications_count: PerformanceLogging.phase("bootstrap.unread_notifications_count") { unread_notifications_count },
          csrf_token: @csrf_token,
          slug_refs: PerformanceLogging.phase("bootstrap.slug_refs") { slug_refs_payload },
          feature_flags: PerformanceLogging.phase("bootstrap.feature_flags") { feature_flags_payload }
        }
        payload[:public] = PerformanceLogging.phase("bootstrap.public") { public_payload } unless user
        payload[:flash] = flash_payload if @flash[:alert].present? || @flash[:notice].present?
        payload
      end
    end

    private

    attr_reader :user

    def me_payload
      return { current_user: nil } unless user

      @me_payload ||= AppApi::MeSerializer.new(user: user).as_json
    end

    def time_zones_payload
      resolution = Rails.application.config.x.server_time_zone
      {
        server: { name: resolution.name, source: resolution.source },
        user: user && { name: user.time_zone, mode: user.time_zone_mode }
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
        ui_engagement_telemetry_enabled: user.present? && AppSetting.ui_engagement_telemetry_enabled?
      }
    end

    def chat_capabilities_payload
      return {} unless user

      {
        speech_to_text: ChatSpeechToText::Capability.for(user: user).as_json,
        coding_mode_enabled: Feature.coding_mode_enabled?,
        local_mode_enabled: Feature.local_mode_enabled?,
        chat_provider_options: User.chat_providers.map do |provider|
          {
            value: provider,
            label: ChatProviders.display_name(provider),
            configured: user.chat_provider_configured?(provider),
            effective_provider: provider,
            effective_label: ChatProviders.display_name(provider)
          }
        end,
        available_chat_models: User.chat_providers.to_h { |provider| [ provider, ChatProviders.available_models(provider) ] }
      }
    end

    def chat_capabilities_payload
      return {} unless user

      {
        speech_to_text: ChatSpeechToText::Capability.for(user: user).as_json,
        coding_mode_enabled: Feature.coding_mode_enabled?,
        local_mode_enabled: Feature.local_mode_enabled?,
        chat_provider_options: User.chat_providers.map do |provider|
          {
            value: provider,
            label: ChatProviders.display_name(provider),
            configured: user.chat_provider_configured?(provider),
            effective_provider: provider,
            effective_label: ChatProviders.display_name(provider)
          }
        end,
        available_chat_models: User.chat_providers.to_h { |provider| [ provider, ChatProviders.available_models(provider) ] }
      }
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

    def setup_payload
      return nil unless user

      {
        complete: user.first_run_setup_complete?,
        chat_started: user.onboarding_chat_started?,
        first_epic_landed: user.first_epic_landed?,
        onboarding_chat_started: user.onboarding_chat_started?
      }
    end

    def flash_payload
      {
        alert: @flash[:alert].presence,
        notice: @flash[:notice].presence
      }
    end

    def system_alerts_payload
      PerformanceLogging.phase("bootstrap.system_alerts.active_for") do
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
    end

    def unread_notifications_count
      return 0 unless user

      me_payload[:unread_notifications_count]
    end

    def feature_flags_payload
      Features::SyncFromYaml.declarations.to_h do |feature|
        slug = feature.fetch(:slug)
        [ slug, Feature.enabled?(slug) ]
      end
    end

    def slug_refs_payload
      {
        types: Syrus::PluginRegistry.providers_for(:slug_type).map(&:client_metadata)
      }
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
