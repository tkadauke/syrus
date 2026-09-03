# frozen_string_literal: true

module Syrus
  # Resolves plugin dependency problems into a state instead of an exception.
  #
  # A misconfigured plugin must never stop Syrus from booting: the operator has
  # to be able to start the instance and fix it from inside. So a plugin whose
  # hard dependency is missing or disabled, or which sits in a dependency cycle,
  # or which conflicts with another enabled plugin, becomes inert -- its
  # providers are withheld from PluginRegistry.providers_for -- rather than
  # taking the process down.
  #
  # States:
  #   :ok        satisfied; providers active
  #   :degraded  enabled, but a hard dependency is missing or disabled, or it
  #              conflicts with another enabled plugin. Providers withheld;
  #              data, admin row, and settings survive.
  #   :cycle     participates in a dependency cycle. Providers withheld.
  #
  # `optionally_depends_on` never produces a bad state - it documents the
  # `defined?(X) && X.enabled?` guard pattern and feeds the admin UI.
  class PluginHealth
    Status = Data.define(:name, :state, :reasons) do
      def ok? = state == :ok
      def healthy? = ok?
    end

    UNHEALTHY_STATES = %i[degraded cycle].freeze

    # `enabled_names` is the set of plugin names currently enabled. Manifests
    # that are installed but disabled still count as "present" for cycle
    # detection, and as "missing" for a hard dependency.
    def initialize(manifests, enabled_names:)
      @manifests = manifests
      @by_name = manifests.index_by(&:name)
      @enabled_names = enabled_names.to_set
    end

    def statuses
      @statuses ||= @manifests.to_h { |manifest| [ manifest.name, status_for(manifest) ] }
    end

    def status(name) = statuses[name]

    def healthy?(name)
      status = statuses[name]
      status.nil? || status.ok?
    end

    def unhealthy
      statuses.values.reject(&:ok?)
    end

    # Cycles are reported over the whole installed set, not just the enabled
    # one: a cycle is a packaging defect that stays true regardless of which
    # plugins an operator happens to have switched on.
    def cycles
      @cycles ||= begin
        found = []
        @by_name.each_key { |name| walk_for_cycles(name, [], found) }
        found.uniq { |cycle| canonical_cycle_key(cycle) }
      end
    end

    private

    def cycle_members
      @cycle_members ||= cycles.flatten.to_set
    end

    def status_for(manifest)
      reasons = []
      state = :ok

      if cycle_members.include?(manifest.name)
        state = :cycle
        cycle = cycles.find { |c| c.include?(manifest.name) }
        reasons << "participates in dependency cycle: #{cycle.join(' -> ')}"
      end

      Array(manifest.depends_on).each do |dependency|
        if !@by_name.key?(dependency)
          state = :degraded if state == :ok
          reasons << "requires #{dependency}, which is not installed"
        elsif !@enabled_names.include?(dependency)
          state = :degraded if state == :ok
          reasons << "requires #{dependency}, which is disabled"
        end
      end

      Array(manifest.conflicts_with).each do |other|
        next unless @enabled_names.include?(other)

        state = :degraded if state == :ok
        reasons << "conflicts with #{other}, which is enabled"
      end

      Status.new(name: manifest.name, state: state, reasons: reasons)
    end

    def walk_for_cycles(name, path, found)
      return unless @by_name.key?(name)

      if (index = path.index(name))
        found << [ *path[index..], name ]
        return
      end

      Array(@by_name[name].depends_on).each do |dependency|
        walk_for_cycles(dependency, [ *path, name ], found)
      end
    end

    def canonical_cycle_key(cycle)
      nodes = cycle[0...-1]
      nodes.each_index.map { |index| nodes.rotate(index) }.min.join("\0")
    end
  end
end
