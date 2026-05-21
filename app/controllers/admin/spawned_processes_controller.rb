module Admin
  # Subprocess inventory for the admin UI. Every claude / codex /
  # grader / git / prepare command spawned through ProcessRunner
  # shows up here with staleness, timeouts, host metrics, and a
  # Kill button. The Kill button stamps kill_requested_at on the
  # row — the owning worker pod polls that flag and terminates the
  # local pid (cross-pod kill via DB; pids aren't portable).
  class SpawnedProcessesController < BaseController
    PER_PAGE = 50

    def index
      SmartFolder.ensure_spawned_process_builtins!

      @active_smart_folder = smart_folder_from_params
      @filter = Admin::SpawnedProcesses::Filter.from_params(params, smart_folder: @active_smart_folder, user: Current.user)
      @schema = ::Filters::Schema.for(subject: :spawned_process, user: Current.user)
      @builtin_smart_folders = SmartFolder.for_subject(:spawned_process).built_in_sidebar_order
      @smart_folders = SmartFolder.for_user(Current.user, subject: :spawned_process)
      @smart_folder_counts = smart_folder_counts(SpawnedProcess.all)
      @primary_builtin_smart_folders, @more_builtin_smart_folders = split_builtin_smart_folders

      @processes = @filter.apply(SpawnedProcess.all).order(started_at: :desc).limit(PER_PAGE * 4).to_a
      @running_count = SpawnedProcess.running.count
    end

    def show
      @process = SpawnedProcess.find(params[:id])
      @host_metrics = @process.host_metrics
    end

    def kill
      process = SpawnedProcess.find(params[:id])
      if process.finished?
        redirect_to admin_processes_path, alert: "Process ##{process.id} is already finalized (#{process.outcome})."
        return
      end

      process.request_kill!(user: Current.user)
      redirect_to admin_processes_path, notice: "Kill requested for process ##{process.id} (#{process.kind}). Worker will pick it up within ~1s."
    end

    private

    def smart_folder_from_params
      return if params[:smart_folder_id].blank?

      SmartFolder.for_subject(:spawned_process).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
        SmartFolder.for_subject(:spawned_process).where(user: Current.user).find_by(id: params[:smart_folder_id])
    end

    def smart_folder_counts(base_scope)
      (@builtin_smart_folders + @smart_folders).to_h do |folder|
        [ folder.id, Admin::SpawnedProcesses::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count ]
      end
    end

    def split_builtin_smart_folders
      primary = []
      more = []

      @builtin_smart_folders.each do |folder|
        case folder.visibility
        when :always
          primary << folder
        when :when_present
          primary << folder if @smart_folder_counts[folder.id].to_i.positive? || @active_smart_folder == folder
        else
          more << folder
        end
      end

      [ primary, more ]
    end
  end
end
