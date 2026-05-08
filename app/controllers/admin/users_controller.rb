module Admin
  class UsersController < BaseController
    def index
      @filter = UsersFilter.new(filter_params)
      @users  = @filter.scope.order(:email_address).limit(500)
    end

    def show
      @user = User.find(params[:id])
      @recent_jobs = @user.jobs.order(created_at: :desc).limit(10)
      # Recent Runs aren't on User directly — go through Jobs.
      @recent_runs = Run.joins(job: {}).where(jobs: { user_id: @user.id })
                        .order(created_at: :desc).limit(10)
      # AdminAction entries the user authored (only meaningful when
      # admin? — but we surface anyway, will be empty for non-admins).
      @recent_admin_actions = AdminAction.where(user: @user)
                                         .order(performed_at: :desc).limit(10)
    end

    def pause_scheduling
      @user = User.find(params[:id])
      @user.update!(scheduling_paused: true)
      AdminAction.log!(user: Current.user, action: :pause_user_scheduling, params: { target_user_id: @user.id })
      redirect_to admin_user_path(@user), notice: "Scheduling paused for #{@user.email_address}."
    end

    def unpause_scheduling
      @user = User.find(params[:id])
      @user.update!(scheduling_paused: false)
      AdminAction.log!(user: Current.user, action: :unpause_user_scheduling, params: { target_user_id: @user.id })
      redirect_to admin_user_path(@user), notice: "Scheduling resumed for #{@user.email_address}."
    end

    private

    def filter_params
      params.permit(:email, :admin, :has_github_token, :has_claude_token, :has_codex_token, :gh_rate)
    end
  end
end
