module Admin
  module Users
    class Payload
      def initialize(params:, actor:)
        @params = params
        @actor = actor
      end

      def index
        SmartFolder.ensure_admin_user_builtins!
        active_folder = active_smart_folder
        filter = display_filter(active_folder)
        base_scope = User.all
        users = filter.apply(base_scope).order(:email_address).limit(500)
        {
          filters: filter.active_filters,
          filter: filter.to_h,
          controls: controls_json,
          count: users.size,
          active_smart_folder_id: active_folder&.id,
          smart_folders: smart_folders(base_scope, active_folder),
          users: users.map { |user| serialize_user_row(user) }
        }
      end

      def show(id)
        serialize_user_detail(User.find(id))
      end

      def pause_scheduling(id)
        user = User.find(id)
        user.update!(scheduling_paused: true)
        AdminAction.log!(user: actor, action: :pause_user_scheduling, params: { target_user_id: user.id })
        serialize_user_detail(user)
      end

      def unpause_scheduling(id)
        user = User.find(id)
        user.update!(scheduling_paused: false)
        AdminAction.log!(user: actor, action: :unpause_user_scheduling, params: { target_user_id: user.id })
        serialize_user_detail(user)
      end

      private

      attr_reader :params, :actor

      def active_smart_folder
        ::Admin::SmartFolderNavigation.active_folder(subject: :admin_user, user: actor, params: params)
      end

      def display_filter(active_folder)
        url_filter = ::Admin::Users::Filter.from_params(params, user: actor)
        return url_filter if url_filter.active?

        ::Admin::Users::Filter.from_params(params, smart_folder: active_folder, user: actor)
      end

      def smart_folders(base_scope, active_folder)
        ::Admin::SmartFolderNavigation.new(
          subject: :admin_user,
          user: actor,
          active_folder: active_folder,
          base_scope: base_scope,
          filter_class: ::Admin::Users::Filter
        ).folders
      end

      def controls_json
        {
          filter_schema: Filters::Schema.for(subject: :admin_user, user: actor)
        }
      end

      def serialize_user_row(user)
        {
          id: user.id,
          email_address: user.email_address,
          name: user.name,
          first_name: user.first_name,
          last_name: user.last_name,
          profile_bio: user.profile_bio,
          profile_location: user.profile_location,
          profile_company: user.profile_company,
          profile_website: user.profile_website,
          display_name: user.display_name,
          github_handle: user.github_handle,
          admin: user.admin?,
          scheduling_paused: user.scheduling_paused?,
          agent_provider: user.agent_provider,
          codex_auth_mode: user.codex_auth_mode,
          has_github_token: user.github_token.present?,
          has_claude_token: user.claude_oauth_token.present?,
          has_codex_token: user.codex_api_key.present? || user.codex_auth_json.present?,
          has_codex_api_key: user.codex_api_key.present?,
          has_codex_auth_json: user.codex_auth_json.present?,
          has_api_token: user.api_token.present?,
          agent_max_turns: user.agent_max_turns,
          github_api_blocked: user.gh_api_blocked?,
          github_api_blocked_at: user.gh_api_blocked_at,
          github_api_blocked_reason: user.gh_api_blocked_reason,
          github_rate_limit: github_rate_limit_payload(user),
          created_at: user.created_at,
          updated_at: user.updated_at
        }
      end

      def serialize_user_detail(user)
        serialize_user_row(user).merge(
          recent_jobs: user.jobs.order(created_at: :desc).limit(10).map do |job|
            {
              id: job.id,
              state: job.state,
              kind: job.kind,
              repository_id: job.repository_id,
              created_at: job.created_at
            }
          end,
          recent_runs: Run.joins(:job).where(jobs: { user_id: user.id })
                          .order(created_at: :desc).limit(10).map do |run|
            {
              id: run.id,
              state: run.state,
              trigger_kind: run.trigger_kind,
              started_at: run.started_at,
              finished_at: run.finished_at
            }
          end,
          recent_admin_actions: AdminAction.where(user: user)
                                           .order(performed_at: :desc).limit(10).map do |action|
            {
              action: action.action,
              performed_at: action.performed_at,
              params: action.params
            }
          end
        )
      end

      def github_rate_limit_payload(user)
        return nil if user.gh_rate_limit_remaining.nil?

        {
          remaining: user.gh_rate_limit_remaining,
          limit: user.gh_rate_limit_limit,
          resource: user.gh_rate_limit_resource,
          reset_at: user.gh_rate_limit_reset_at,
          observed_at: user.gh_rate_limit_observed_at,
          percent: user.gh_rate_limit_limit.to_i.positive? ?
                     (user.gh_rate_limit_remaining.to_f / user.gh_rate_limit_limit) : nil
        }
      end
    end
  end
end
