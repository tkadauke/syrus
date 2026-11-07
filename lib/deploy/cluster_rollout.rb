# frozen_string_literal: true

module Deploy
  # One cluster, start to finish.
  #
  # The order is the design. Reading it top to bottom is meant to be the
  # fastest way to understand what a deploy does, so each line is a phase and
  # the reasons live in the phases.
  #
  # Three orderings are load-bearing and have each been got wrong at some
  # point:
  #
  #   Flux's desired state is pinned *before* the live workloads, so resuming
  #   Flux finds the pod template that just rolled out rather than starting a
  #   second rollout of its own.
  #
  #   The image is pre-pulled *before* the live pod template changes. Warming
  #   nodes whose pods have already paid the pull warms nothing.
  #
  #   Migrations run *before* the images are pinned. The new code must never
  #   serve traffic against a schema it has not been given, and that is also
  #   why they run from the new image rather than the one already deployed.
  class ClusterRollout
    attr_reader :context, :images

    def initialize(context:, images:)
      @context = context
      @images = images
    end

    def roll!
      targets = present_rollout_targets
      pins = ImagePins.new(context, registries: images.all_registries)

      flux = Flux.new(context)
      # Plugin and operator-owned workloads extend the watchdog budget;
      # the configured targets are already counted, so only the extras are
      # added rather than every workload running one of our images.
      extra_targets = pins.our_containers.map(&:target).uniq - targets
      flux.configure_ttl!(targets.length + extra_targets.length)
      flux.suspend!
      flux.pin_desired_images!(images.all_registries)

      backup = MysqlBackup.new(context)
      backup.suspend!

      MiseCache.new(context).apply!
      Prepull.new(context).warm!
      Migrations.new(context).run!

      pins.pin!

      rollout_wait = RolloutWait.new(context)
      (targets | pins.pinned_targets).each { |target| rollout_wait.wait!(target) }

      Verifications.new(context).verify_all!(targets)

      backup.resume!
      flux.resume!
      flux.verify_desired_images!(images.all_registries)
      flux.accept_desired_images!

      reporter.ok("#{label} rolled to #{sha}")
    end

    private

    # A deployment that is simply not installed in this namespace -- the
    # preview service on a cluster that does not run previews -- is skipped
    # with a note, not an error. None of them existing is an error: it means
    # this is not a Syrus namespace, and proceeding would suspend Flux and
    # migrate a database for nothing.
    def present_rollout_targets
      targets = config.rollout_targets.select do |target|
        next true if kubectl.exists?(target)

        reporter.step("#{label}: rollout target #{target} not found in #{kubectl.namespace} — skipping")
        false
      end

      if targets.empty?
        raise Failure.new("#{label}: no rollout targets found in #{kubectl.namespace}")
      end

      targets
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def label = context.label
    def sha = context.sha
  end
end
