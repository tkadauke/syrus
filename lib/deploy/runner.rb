# frozen_string_literal: true

module Deploy
  # The whole deploy: preflight, images, then each cluster in turn.
  class Runner
    attr_reader :config, :reporter, :shell, :clock, :controls, :repo, :images

    def initialize(config:, reporter: Reporter.new)
      @config = config
      @reporter = reporter
      @clock = config.dry_run ? Clock::Immediate.new : Clock.new
      @stream = open_dry_run_stream
      @shell = Shell.new(reporter: reporter, clock: @clock, dry_run: config.dry_run, stream: @stream)
      @controls = ControlStack.new(reporter: reporter)
      @repo = Repo.new(shell: @shell, reporter: reporter)
      @images = Images.new(config: config, repo: @repo, shell: @shell, reporter: reporter)
    end

    def call
      preflight!
      images.ensure_available!

      if config.build_only
        reporter.ok("images built and pushed for #{repo.sha}; skipping rollout (--build-only)")
        return 0
      end

      config.clusters.each { |cluster| deploy_to(cluster) }
      report_success
      0
    rescue Interrupted => e
      reporter.error(e.message)
      unwind(interrupted: true)
      e.exit_status
    rescue Failure => e
      reporter.error(e.message)
      reporter.detail(e.detail)
      unwind
      e.exit_status
    ensure
      unwind
      @stream&.close unless @stream.nil? || @stream.equal?($stdout)
    end

    private

    def preflight!
      repo.assert_clean!
      reporter.step("deploying #{repo.sha} (branch #{repo.branch})")
      eager_load_probe!
    end

    # Catches the Zeitwerk superclass-mismatch crashes that lazy autoloading in
    # development and test hides, and that otherwise surface as a web pod that
    # will not boot after the images are already pushed and the rollout is
    # under way. Shared with the agent's grade step, so the same check runs in
    # both contexts.
    #
    # Skipped under --skip-build, where the image was built and probed by the
    # run that produced it.
    def eager_load_probe!
      return if config.skip_build
      return unless File.executable?("bin/check-eager-load")

      reporter.step("eager_load probe")
      shell.stream_write([ "bash", "-c", "bundle check >/dev/null || bundle install" ])
      result = shell.stream_write([ "bin/check-eager-load", "--quiet" ])
      raise Failure.new("eager_load probe failed") unless result.success?
    end

    def deploy_to(cluster)
      context = ClusterContext.new(
        label: cluster.label,
        sha: repo.sha,
        config: config,
        kubectl: Kubectl.new(shell: shell, kubeconfig: cluster.kubeconfig, namespace: cluster.namespace),
        flux_kubectl: Kubectl.new(shell: shell, kubeconfig: cluster.kubeconfig, namespace: config.flux_namespace),
        reporter: reporter,
        waiter: Waiter.new(clock: clock, reporter: reporter, dry_run: config.dry_run),
        controls: controls,
        clock: clock
      )

      ClusterRollout.new(context: context, images: images).roll!

      # The release tag records what landed, so it moves only after the cluster
      # it names has actually converged and been verified.
      repo.move_release_tag(cluster.label)
      reporter.step("#{cluster.label} tag → #{repo.sha}")
    end

    def report_success
      reporter.plain
      reporter.ok("deployed #{repo.sha}#{config.clusters.map { |c| " · #{c.label}" }.join}")
    end

    def unwind(interrupted: false)
      return if @unwound

      @unwound = true
      controls.unwind(interrupted: interrupted)
    end

    # A dedicated sink, so a dry run's command stream cannot be lost to a call
    # site that discards output. In the bash implementation the stream went to
    # stdout, and the Flux and cronjob suspend patches end in `>/dev/null` --
    # which silently dropped precisely the writes the stream exists to record.
    def open_dry_run_stream
      return nil unless config.dry_run
      return $stdout if config.dry_run_stream_path.nil?

      File.open(config.dry_run_stream_path, "w")
    end
  end
end
