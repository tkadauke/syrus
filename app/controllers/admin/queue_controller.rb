module Admin
  # Admin queue inspector. Surfaces SolidQueue's tables so the
  # operator can spot starvation, pruned-worker zombies, stuck
  # recurring jobs, and ailing workers without dropping into a
  # Rails console. See docs/plans/complete/admin-diagnostics.md (B).
  #
  # All queries are wrapped in a SolidQueue-tables-reachable guard
  # because dev/test runs single-database (no separate queue DB);
  # the page degrades to "queue tables unreachable from this
  # connection" instead of 500ing.
  class QueueController < BaseController
    PER_PAGE = 50

    def index
      redirect_to admin_queue_path("active")
    end

    def show
      @tab = params[:tab].to_s
      @page = [ params.fetch(:page, 1).to_i, 1 ].max

      with_queue_tables do
        case @tab
        when "active"
          prepare_filter(:active)
          load_active
        when "pending"
          prepare_filter(:pending)
          load_pending
        when "failed"
          prepare_filter(:failed)
          load_failed
        when "recurring"  then load_recurring
        when "workers"    then load_workers
        else
          redirect_to admin_queue_path(tab: "active") and return
        end
      end
    end

    # Fast-path the operator for the most common "things look
    # stuck, just reap them" intervention. Same code path that
    # the recurring ReapStaleRunsJob runs every minute — manual
    # button is for when the recurring job itself is starved.
    def reap_stale_runs
      ReapStaleRunsJob.perform_now
      redirect_to admin_queue_path("active"),
                  notice: "ReapStaleRunsJob ran inline."
    end

    private

    # Wrap the body in a broad rescue so the view never sees an
    # AR error from SQ tables being absent (dev/test single-DB
    # setup) or unreachable. Materialize results inside the rescue
    # via `.to_a` so the lazy AR relation can't leak the exception
    # into the view layer. Sets @queue_unreachable so the view
    # renders a friendly placeholder.
    def with_queue_tables
      yield
    rescue ActiveRecord::StatementInvalid,
           ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::ActiveRecordError => e
      @queue_unreachable = e.message
      Rails.logger.debug("[Admin::Queue] queue tables unreachable: #{e.class}: #{e.message}")
    end

    def load_active
      base = SolidQueue::Job.joins(:claimed_execution)
      @active = @filter
        .apply(base)
        .order("solid_queue_claimed_executions.created_at DESC")
        .limit(PER_PAGE)
        .to_a  # materialize — keep the rescue around the query
      load_smart_folder_counts(base)
    end

    def load_pending
      base = SolidQueue::Job.joins(:ready_execution)
      filtered = @filter.apply(base)
      @pending_total = filtered.count
      @pending = filtered
        .order("solid_queue_ready_executions.created_at ASC")
        .limit(PER_PAGE)
        .offset((@page - 1) * PER_PAGE)
        .to_a
      load_smart_folder_counts(base)
    end

    def load_failed
      base = SolidQueue::FailedExecution.includes(:job).references(:job)
      @failed = @filter
        .apply(base)
        .order(created_at: :desc)
        .limit(PER_PAGE)
        .to_a
      load_smart_folder_counts(base)
    end

    def load_recurring
      @recurring = SolidQueue::RecurringTask.order(:key).to_a.map do |task|
        last = SolidQueue::RecurringExecution.where(task_key: task.key).order(run_at: :desc).first
        {
          key: task.key,
          class_name: task.class_name,
          schedule: task.schedule,
          last_run_at: last&.run_at,
          last_finished_at: last && SolidQueue::Job.find_by(id: last.job_id)&.finished_at
        }
      end
    end

    def load_workers
      @workers = SolidQueue::Process.where(kind: "Worker").order(:hostname, :pid).to_a
      @processes_all = SolidQueue::Process.order(:kind, :hostname, :pid).to_a
    end

    def prepare_filter(tab)
      SmartFolder.ensure_admin_queue_builtins!
      @active_smart_folder = admin_queue_smart_folder_from_params
      @filter = Admin::Queue::Filter.from_params(params, smart_folder: @active_smart_folder, user: Current.user, tab: tab)
      @schema = ::Filters::Schema.for(subject: :admin_queue, user: Current.user)
      @smart_folders = SmartFolder.for_subject(:admin_queue).where(user: Current.user).order(:position, :id)
      @builtin_smart_folders = SmartFolder.for_subject(:admin_queue).built_in_sidebar_order
    end

    def admin_queue_smart_folder_from_params
      return if params[:smart_folder_id].blank?

      SmartFolder.for_subject(:admin_queue).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
        SmartFolder.for_subject(:admin_queue).where(user: Current.user).find_by(id: params[:smart_folder_id])
    end

    def load_smart_folder_counts(base_scope)
      @smart_folder_counts = (@builtin_smart_folders + @smart_folders).to_h do |folder|
        count = Admin::Queue::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count
        [ folder.id, count ]
      end
    end
  end
end
