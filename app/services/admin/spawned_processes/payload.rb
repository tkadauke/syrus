module Admin
  module SpawnedProcesses
    class Payload
      PER_PAGE = 100

      def initialize(params:, user:, per_page: PER_PAGE)
        @params = params
        @user = user
        @per_page = per_page
      end

      def index
        SmartFolder.ensure_spawned_process_builtins!
        active_folder = active_smart_folder
        base_scope = SpawnedProcess.all
        filter = display_filter(active_folder)
        scope = filter.apply(base_scope).order(started_at: :desc).limit(@per_page)

        {
          filter: filter.to_h,
          controls: controls_json,
          processes: scope.to_a.map { |process| serialize(process) },
          running_total: SpawnedProcess.running.count,
          active_smart_folder_id: active_folder&.id,
          smart_folders: smart_folders(base_scope, active_folder)
        }
      end

      def show(id)
        serialize(SpawnedProcess.find(id), include_host_metrics: true)
      end

      def kill(id, user:)
        process = SpawnedProcess.find(id)
        return already_finished_payload(process) if process.finished?

        process.request_kill!(user: user)
        serialize(process.reload, include_host_metrics: true)
      end

      private

      attr_reader :params, :user

      def active_smart_folder
        ::Admin::SmartFolderNavigation.active_folder(subject: :spawned_process, user: user, params: params)
      end

      def display_filter(active_folder)
        url_filter = ::Admin::SpawnedProcesses::Filter.from_params(params, user: user)
        return url_filter if url_filter.active?

        ::Admin::SpawnedProcesses::Filter.from_params(params, smart_folder: active_folder, user: user)
      end

      def smart_folders(base_scope, active_folder)
        ::Admin::SmartFolderNavigation.new(
          subject: :spawned_process,
          user: user,
          active_folder: active_folder,
          base_scope: base_scope,
          filter_class: ::Admin::SpawnedProcesses::Filter
        ).folders
      end

      def controls_json
        {
          filter_schema: Filters::Schema.for(subject: :spawned_process, user: user)
        }
      end

      def already_finished_payload(process)
        {
          error: {
            code: "already_finished",
            message: "Process is finalized (#{process.outcome})."
          },
          status: :conflict
        }
      end

      def serialize(process, include_host_metrics: false)
        payload = {
          id: process.id,
          kind: process.kind,
          command: process.command,
          workdir: process.workdir,
          hostname: process.hostname,
          pid: process.pid,
          pgid: process.pgid,
          started_at: process.started_at&.iso8601,
          last_chunk_at: process.last_chunk_at&.iso8601,
          finished_at: process.finished_at&.iso8601,
          duration_s: process.duration_s,
          exit_status: process.exit_status,
          outcome: process.outcome,
          wall_timeout_s: process.wall_timeout_s,
          silent_timeout_s: process.silent_timeout_s,
          run_id: process.run_id,
          workflow_id: process.workflow_id,
          workflow_slug: process.workflow&.slug,
          workflow_path: process.workflow ? App::WorkflowNavigation.path(process.workflow) : nil,
          stale: process.stale?,
          kill_requested_at: process.kill_requested_at&.iso8601,
          kill_requested_by_user_id: process.kill_requested_by_user_id
        }
        payload[:host_metrics] = process.host_metrics if include_host_metrics
        payload
      end
    end
  end
end
