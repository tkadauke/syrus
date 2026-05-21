module Admin
  class UsersController < BaseController
    def index
      SmartFolder.ensure_admin_user_builtins!
      @smart_folder = smart_folder_from_params
      @filter = ::Admin::Users::Filter.from_params(params, smart_folder: @smart_folder, user: Current.user)
      @schema = ::Filters::Schema.for(subject: :admin_user, user: Current.user)
      @smart_folders = SmartFolder.for_subject(:admin_user).where(user: Current.user).order(:position, :id)
      @builtin_smart_folders = SmartFolder.for_subject(:admin_user).built_in_sidebar_order
      @smart_folder_counts = smart_folder_counts(User.all)
      @primary_builtin_smart_folders, @more_builtin_smart_folders = split_builtin_smart_folders
      @users = @filter.apply(User.all).order(:email_address).limit(500)
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

    def smart_folder_from_params
      return if params[:smart_folder_id].blank?

      SmartFolder.for_subject(:admin_user).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
        SmartFolder.for_subject(:admin_user).where(user: Current.user).find_by(id: params[:smart_folder_id])
    end

    def smart_folder_counts(base_scope)
      (@builtin_smart_folders + @smart_folders).to_h do |folder|
        [ folder.id, ::Admin::Users::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count ]
      end
    end

    def split_builtin_smart_folders
      primary = []
      more = []

      @builtin_smart_folders.each do |folder|
        case folder.visibility
        when :always
          primary << folder
        when :on_demand
          more << folder
        when :when_present
          primary << folder if @smart_folder_counts[folder.id].to_i.positive? || @smart_folder == folder
        else
          primary << folder
        end
      end

      [ primary, more ]
    end
  end
end
