# frozen_string_literal: true

module Deploy
  # Hold the MySQL backup off for the duration of the rollout.
  #
  # A backup running while pods are replaced competes with the migration for
  # the same database and, on this hardware, for the same memory headroom. It
  # is also the one job in the cluster whose interruption costs nothing to
  # retry -- it runs on a schedule and the next tick picks it up -- so pausing
  # it is cheap insurance.
  #
  # A backup that is *already* running is drained rather than killed on sight:
  # it gets a grace period to finish, and is only deleted if it is still going
  # after that. A half-written backup is worth less than no backup.
  class MysqlBackup
    attr_reader :context

    def initialize(context)
      @context = context
      @suspended_by_deploy = false
    end

    def suspend!
      unless present?
        reporter.step("#{label}: mysql backup cronjob '#{config.mysql_backup_cronjob}' not found — proceeding")
        return
      end

      if already_suspended?
        # The operator suspended this. Resuming it on our way out would undo
        # a decision this script knows nothing about.
        reporter.step("#{label}: cronjob/#{config.mysql_backup_cronjob} was already suspended — leaving it suspended")
        return
      end

      reporter.step("#{label}: suspending cronjob/#{config.mysql_backup_cronjob} during rollout")
      patch_suspend(true)
      @suspended_by_deploy = true
      controls.push(control_name) { resume! }

      drain!
    end

    def resume!
      if @suspended_by_deploy && present?
        reporter.step("#{label}: resuming cronjob/#{config.mysql_backup_cronjob}")
        patch_suspend(false)
      end
      @suspended_by_deploy = false
      controls.discharge(control_name)
    end

    private

    def control_name
      "cronjob/#{config.mysql_backup_cronjob} suspension"
    end

    def drain!
      return if waiter.skip?

      waiter.until(
        label: "#{label}: mysql backup drain",
        timeout: config.mysql_backup_drain_timeout,
        poll: 5,
        report_every: 10
      ) do
        running = running_backup_jobs
        running.empty? ? Waiter.converged : Waiter.pending("#{label}: waiting for mysql backup #{running.join(", ")}")
      end
    rescue Failure
      running = running_backup_jobs
      return if running.empty?

      reporter.warn("#{label}: mysql backup still running after #{Duration.humanize(config.mysql_backup_drain_timeout)}; deleting it before rollout")
      running.each { |job| kubectl.delete("job", job) }
    end

    def running_backup_jobs
      prefix = "#{config.mysql_backup_cronjob}-"
      kubectl
        .jsonpath("pods", '{range .items[?(@.status.phase=="Running")]}{.metadata.labels.job-name}{"\n"}{end}')
        .lines
        .map(&:strip)
        .select { |name| name.start_with?(prefix) }
        .uniq
    end

    def present?
      kubectl.exists?("cronjob", config.mysql_backup_cronjob)
    end

    def already_suspended?
      kubectl.jsonpath("cronjob", config.mysql_backup_cronjob, "{.spec.suspend}") == "true"
    end

    def patch_suspend(value)
      kubectl.patch("cronjob", config.mysql_backup_cronjob, patch: { "spec" => { "suspend" => value } })
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def controls = context.controls
    def label = context.label
  end
end
