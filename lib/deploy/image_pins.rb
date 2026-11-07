# frozen_string_literal: true

module Deploy
  # Point every live container that runs one of our images at this revision.
  #
  # Changing the image is the only rollout trigger. An additional `rollout
  # restart` writes an imperative annotation, which produces a ReplicaSet that
  # differs from the previous one in nothing but that annotation -- and Flux
  # strips the annotation when it resumes, replacing every pod a second time
  # for no reason.
  #
  # The containers to pin are discovered from the cluster rather than listed
  # here. The previous implementation named four workloads and eight container
  # names in the script, and the failure that produced -- "a deployment,
  # daemonset, or init container was added without a matching entry" -- was
  # written into its own error message, which is the clearest possible sign
  # that the list was the wrong shape. Discovery also matches what the Flux
  # image override does, since that override applies to every resource using
  # the repository, so the live pin and the desired pin now agree by
  # construction instead of by maintenance.
  class ImagePins
    WORKLOAD_KINDS = "deploy,ds,sts"

    Container = Struct.new(:target, :container, :repository, keyword_init: true)

    attr_reader :context, :pinned_targets

    def initialize(context, registries:)
      @context = context
      @registries = registries
      @pinned_targets = []
    end

    def pin!
      containers = our_containers
      if containers.empty?
        raise Failure.new("#{label}: no workload in #{kubectl.namespace} runs a Syrus image; nothing to pin")
      end

      reporter.step("#{label}: pinning live workloads to #{sha}")
      ordered(containers.group_by(&:target)).each do |target, group|
        pairs = group.map { |entry| "#{entry.container}=#{entry.repository}:#{sha}" }
        reporter.step("#{label}: #{target} → #{group.map(&:container).join(", ")}")
        kubectl.set_image(target, pairs)
        @pinned_targets << target
      end
      @pinned_targets.uniq!
    end

    # Every container (init containers included) of a Deployment, DaemonSet or
    # StatefulSet whose image repository is one of ours, at any tag or digest.
    # Matching on the repository and ignoring the tag is what lets this find a
    # workload that is already on the right revision, or on a digest, or on
    # `:latest`.
    def our_containers
      @our_containers ||= begin
        document = kubectl.get_json(WORKLOAD_KINDS) || {}
        Array(document["items"]).flat_map { |item| containers_of(item) }
      end
    end

    private

    # The configured rollout targets first, in the order the operator listed
    # them, then anything else discovered. Pinning is what triggers each
    # workload's rollout, and nothing waits between pins, so the order does not
    # change the outcome -- but a deploy whose first visible move is always the
    # web deployment is easier to read than one that follows whatever order
    # kubectl happened to list resources in.
    def ordered(groups)
      priority = context.config.rollout_targets
      groups.sort_by do |target, _|
        [ priority.index(target) || priority.length, target ]
      end
    end

    def containers_of(item)
      target = "#{item.fetch("kind").downcase}/#{item.dig("metadata", "name")}"
      spec = item.dig("spec", "template", "spec") || {}

      (Array(spec["containers"]) + Array(spec["initContainers"])).filter_map do |container|
        repository = repository_of(container["image"])
        next unless @registries.include?(repository)

        Container.new(target: target, container: container["name"], repository: repository)
      end
    end

    # Strip a digest, then a tag. Only a trailing `:tag` with no `/` after it
    # is a tag -- a registry host with a port would otherwise lose its port.
    def repository_of(image)
      image.to_s.sub(/@.*\z/, "").sub(%r{:[^/:]+\z}, "")
    end

    def kubectl = context.kubectl
    def reporter = context.reporter
    def label = context.label
    def sha = context.sha
  end
end
