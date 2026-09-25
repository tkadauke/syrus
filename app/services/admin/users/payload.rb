module Admin
  module Users
    class Payload
      DEFAULT_PER_PAGE = 100
      MAX_PER_PAGE = 200
      SORTS = {
        "email" => { email_address: :asc },
        "github" => { github_handle: :asc },
        "admin" => { admin: :asc },
        "role" => { role: :asc },
        "agent" => { agent_provider: :asc },
        "scheduling" => { scheduling_paused: :asc },
        "created_at" => { created_at: :asc },
        "updated_at" => { updated_at: :asc }
      }.freeze
      DEFAULT_SORT = "email"

      def initialize(params:, actor:)
        @params = params
        @actor = actor
      end

      def index
        SmartFolder.ensure_admin_user_builtins!
        active_folder = active_smart_folder
        filter = display_filter(active_folder)
        base_scope = User.all
        filtered = filter.apply(base_scope)
        total = filtered.count
        users = apply_sort(filtered).offset(offset).limit(per_page)
        {
          filters: filter.active_filters,
          filter: filter.to_h,
          controls: controls_json,
          count: total,
          pagination: pagination_payload(total),
          sort: sort_payload,
          active_smart_folder_id: active_folder&.id,
          smart_folders: smart_folders(base_scope, active_folder),
          users: users.map { |user| serialize_user_row(user) }
        }
      end

      def show(id)
        serialize_user_detail(User.find(id))
      end

      def pause_scheduling(id)
        require_admin!
        user = User.find(id)
        user.update!(scheduling_paused: true)
        AdminAction.log!(user: actor, action: :pause_user_scheduling, params: { target_user_id: user.id })
        serialize_user_detail(user)
      end

      def unpause_scheduling(id)
        require_admin!
        user = User.find(id)
        user.update!(scheduling_paused: false)
        AdminAction.log!(user: actor, action: :unpause_user_scheduling, params: { target_user_id: user.id })
        serialize_user_detail(user)
      end

      def update(id, attributes)
        require_admin!
        user = User.find(id)
        user.update!(attributes.to_h.symbolize_keys.slice(:role))
        AdminAction.log!(user: actor, action: :update_user_role, params: { target_user_id: user.id, role: user.role })
        serialize_user_detail(user)
      end

      private

      attr_reader :params, :actor

      def page
        [ params[:page].to_i, 1 ].max
      end

      def per_page
        raw = params[:per_page].to_i
        return DEFAULT_PER_PAGE unless raw.positive?

        [ raw, MAX_PER_PAGE ].min
      end

      def offset
        (page - 1) * per_page
      end

      def sort_column
        SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : DEFAULT_SORT
      end

      def sort_direction
        params[:direction].to_s == "desc" ? "desc" : "asc"
      end

      def apply_sort(scope)
        order = SORTS.fetch(sort_column)
        direction = sort_direction.to_sym
        scope.order(order.transform_values { direction }).order(id: direction)
      end

      def sort_payload
        {
          column: sort_column,
          direction: sort_direction
        }
      end

      def pagination_payload(total)
        total_pages = (total.to_f / per_page).ceil
        {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total_pages,
          has_previous_page: page > 1,
          has_next_page: total_pages > page,
          previous_page: page > 1 ? page - 1 : nil,
          next_page: total_pages > page ? page + 1 : nil,
          first_item: total.zero? ? 0 : offset + 1,
          last_item: [ offset + per_page, total ].min
        }
      end

      def require_admin!
        raise ArgumentError, "Admin access required." unless actor&.admin?
      end

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
          role: user.role,
          scheduling_paused: user.scheduling_paused?,
          agent_provider: user.agent_provider,
          chat_provider: user.chat_provider,
          codex_auth_mode: user.codex_auth_mode,
          has_github_token: user.github_token.present?,
          has_claude_token: user.claude_oauth_token.present?,
          has_codex_token: user.codex_api_key.present? || user.codex_auth_json.present?,
          has_codex_api_key: user.codex_api_key.present?,
          has_codex_auth_json: user.codex_auth_json.present?,
          has_muse_token: user.muse_api_key.present?,
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
