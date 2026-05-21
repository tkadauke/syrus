module Api
  module V1
    module Admin
      # Mirror of Admin::UsersController. Same Admin::Users::Filter
      # so HTML + API never drift.
      #
      #   GET /api/v1/admin/users          — filtered list
      #   GET /api/v1/admin/users/:id      — full user detail
      class UsersController < BaseController
        def index
          filter = ::Admin::Users::Filter.from_params(params, user: Current.user)
          users = filter.apply(User.all).order(:email_address).limit(500)
          render json: {
            filters: filter.active_filters,
            count:   users.size,
            users:   users.map { |u| serialize_user_row(u) }
          }
        end

        def show
          user = User.find(params[:id])
          render json: serialize_user_detail(user)
        end

        private

        def serialize_user_row(user)
          {
            id:                user.id,
            email_address:     user.email_address,
            admin:             user.admin?,
            agent_provider:    user.agent_provider,
            codex_auth_mode:   user.codex_auth_mode,
            has_github_token:  user.github_token.present?,
            has_claude_token:  user.claude_oauth_token.present?,
            has_codex_token:   user.codex_api_key.present? || user.codex_auth_json.present?,
            has_codex_api_key: user.codex_api_key.present?,
            has_codex_auth_json: user.codex_auth_json.present?,
            agent_max_turns:   user.agent_max_turns,
            github_rate_limit: github_rate_limit_payload(user),
            created_at:        user.created_at
          }
        end

        def serialize_user_detail(user)
          serialize_user_row(user).merge(
            recent_jobs: user.jobs.order(created_at: :desc).limit(10).map do |j|
              { id: j.id, state: j.state, kind: j.kind, repository_id: j.repository_id, created_at: j.created_at }
            end,
            recent_runs: Run.joins(:job).where(jobs: { user_id: user.id })
                            .order(created_at: :desc).limit(10).map do |r|
              { id: r.id, state: r.state, trigger_kind: r.trigger_kind, started_at: r.started_at, finished_at: r.finished_at }
            end,
            recent_admin_actions: AdminAction.where(user: user)
                                             .order(performed_at: :desc).limit(10).map do |a|
              { action: a.action, performed_at: a.performed_at, params: a.params }
            end
          )
        end

        def github_rate_limit_payload(user)
          return nil if user.gh_rate_limit_remaining.nil?
          {
            remaining:   user.gh_rate_limit_remaining,
            limit:       user.gh_rate_limit_limit,
            resource:    user.gh_rate_limit_resource,
            reset_at:    user.gh_rate_limit_reset_at,
            observed_at: user.gh_rate_limit_observed_at,
            percent:     user.gh_rate_limit_limit.to_i.positive? ?
                           (user.gh_rate_limit_remaining.to_f / user.gh_rate_limit_limit) : nil
          }
        end
      end
    end
  end
end
