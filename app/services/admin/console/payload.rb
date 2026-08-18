module Admin
  module Console
    class Payload
      def initialize(actor:)
        @actor = actor
      end

      def show
        {
          settings: settings_payload,
          users: users_payload,
          recent_admin_actions: recent_admin_actions_payload,
          active_runs: Run.active.count
        }
      end

      def pause_polling(source:)
        update_flag!(polling_paused: true, action: :pause_polling, source: source)
      end

      def unpause_polling(source:)
        update_flag!(polling_paused: false, action: :unpause_polling, source: source)
      end

      def pause_runs(source:)
        update_flag!(runs_paused: true, action: :pause_runs, source: source)
      end

      def unpause_runs(source:)
        update_flag!(runs_paused: false, action: :unpause_runs, source: source)
      end

      def enable_merge_train(source:)
        update_flag!(merge_train_enabled: true, action: :enable_merge_train, source: source)
      end

      def disable_merge_train(source:)
        update_flag!(merge_train_enabled: false, action: :disable_merge_train, source: source)
      end

      def clear_github_cache(user_id:, source:)
        pattern, summary = github_cache_scope(user_id)
        cleared = clear_cache_pattern(pattern)
        AdminAction.log!(user: actor, action: :clear_github_cache, params: { source: source, scope: pattern, cleared_count: cleared })
        show.merge(ok: true, message: "Cleared #{cleared} GitHub cache entries #{summary}.")
      end

      private

      attr_reader :actor

      def update_flag!(attrs)
        action = attrs.delete(:action)
        source = attrs.delete(:source)
        AppSetting.current.update!(attrs)
        AdminAction.log!(user: actor, action: action, params: { source: source })
        show.merge(ok: true)
      end

      def settings_payload
        settings = AppSetting.current
        {
          polling_paused: settings.polling_paused,
          runs_paused: settings.runs_paused,
          signups_open: settings.signups_open,
          max_job_failures: settings.max_job_failures,
          grade_max_iterations: settings.grade_max_iterations,
          merge_train_enabled: settings.merge_train_enabled
        }
      end

      def users_payload
        User.order(:email_address).map do |user|
          {
            id: user.id,
            email_address: user.email_address,
            display_name: user.display_name
          }
        end
      end

      def recent_admin_actions_payload
        AdminAction.recent.includes(:user).map do |action|
          {
            id: action.id,
            action: action.action,
            performed_at: action.performed_at,
            user_email: action.user.email_address,
            params: action.params
          }
        end
      end

      def github_cache_scope(user_id)
        if user_id.present?
          user = User.find(user_id)
          [ "github_etag/u#{user.id}/*", "for #{user.email_address}" ]
        else
          [ "github_etag/*", "for all users" ]
        end
      end

      def clear_cache_pattern(pattern)
        Rails.cache.delete_matched(pattern)
      rescue NotImplementedError, StandardError => e
        Rails.logger.warn("[Admin::Console] cache clear failed: #{e.class}: #{e.message}")
        0
      end
    end
  end
end
