module BuildCache
  # Snapshots sccache statistics after each shell command a step runs.
  #
  # This used to be Steps::Base#capture_sccache_stats!, called explicitly from
  # three step classes. It is now a subscriber to step.command.completed, which
  # is delivered inline precisely so this can still reach the workspace and the
  # command's own scrubbed environment before the workspace is torn down.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      { "step.command.completed" => :on_command_completed }
    end

    def self.on_command_completed(event)
      workflow = Workflow.find_by(id: event[:workflow_id])
      run = Run.find_by(id: event[:run_id])
      return if workflow.nil? || run.nil?

      stats = StatsCapture.capture(env: event[:env], chdir: Pathname.new(event[:workspace_path].to_s))
      return if stats.nil?

      StatsArtifact.record!(
        workflow,
        run: run,
        step_kind: event[:step_kind],
        label: event[:label],
        stats: stats
      )
    end
  end
end
