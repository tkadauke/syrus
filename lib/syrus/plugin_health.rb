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
  #   :warning   diagnostic finding; providers remain active
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
      def healthy? = %i[ok warning].include?(state)
    end

    UNHEALTHY_STATES = %i[degraded cycle incompatible failed duplicate_name skipped_dependency skipped_role quarantined].freeze

    # `enabled_names` is the set of plugin names currently enabled. Manifests
    # that are installed but disabled still count as "present" for cycle
    # detection, and as "missing" for a hard dependency.
    def initialize(manifests, enabled_names:)
      @manifests = manifests
      @by_name = manifests.index_by(&:name)
      @enabled_names = enabled_names.to_set
    end

    def statuses
      @statuses ||= propagate_unhealthy_dependencies(@manifests.to_h { |manifest| [ manifest.name, status_for(manifest) ] })
    end

    def status(name) = statuses[name]

    def healthy?(name)
      status = statuses[name]
      status.nil? || status.healthy?
    end

    def unhealthy
      statuses.values.select { |status| UNHEALTHY_STATES.include?(status.state) }
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

    # A contribution is callable only when its plugin's whole required
    # dependency closure is healthy, not just enabled. An enabled plugin whose
    # hard dependency is enabled but itself unhealthy (degraded, failed,
    # incompatible, ...) is degraded too, and so on up the chain. Only ever
    # turns healthy into degraded, so it reaches a fixed point; cycle members
    # are already unhealthy (formal/SyrusModel/PluginClosure.lean).
    def propagate_unhealthy_dependencies(statuses)
      loop do
        changed = false
        statuses.each do |name, status|
          next unless status.healthy? && @enabled_names.include?(name)

          broken = Array(@by_name[name].depends_on).filter_map do |dependency|
            dependency_status = statuses[dependency]
            next unless dependency_status && @enabled_names.include?(dependency) && !dependency_status.healthy?

            "requires #{dependency}, which is #{dependency_status.state}"
          end
          next if broken.empty?

          statuses[name] = Status.new(name: name, state: :degraded, reasons: status.reasons + broken)
          changed = true
        end
        return statuses unless changed
      end
    end

    def status_for(manifest)
      reasons = []
      state = :ok

      if manifest.external && manifest.requires_syrus
        if SyrusVersion.release.nil?
          reasons << "requires Syrus #{manifest.requires_syrus}; running release version is unknown, compatibility check skipped"
        elsif !manifest.requires_syrus.satisfied_by?(SyrusVersion.release)
          state = :incompatible
          reasons << "requires Syrus #{manifest.requires_syrus}; running release is #{SyrusVersion.release}"
        end
      end

      if manifest.external && (scan = manifest.metadata.to_h[:plugin_host_surface_scan])
        scan_reasons = []
        scan_reasons << I18n.t("api.plugins.host_surface.scan_failed", error: scan.error) if scan.error
        scan_reasons << I18n.t("api.plugins.host_surface.unsupported", count: scan.unlisted.size) if scan.unlisted.any?
        scan_reasons << I18n.t("api.plugins.host_surface.legacy", count: scan.legacy.size) if scan.legacy.any?
        scan_reasons << I18n.t("api.plugins.host_surface.dynamic", count: scan.dynamic.size) if scan.dynamic.any?
        declared = declared_minimum(manifest.requires_syrus)
        if scan.minimum_syrus_version && declared && declared < Gem::Version.new(scan.minimum_syrus_version)
          scan_reasons << I18n.t("api.plugins.host_surface.minimum", declared:, derived: scan.minimum_syrus_version)
        end
        unless scan_reasons.empty?
          state = :warning if state == :ok
          reasons.concat(scan_reasons)
        end
      end

      unless manifest.loaded
        return Status.new(name: manifest.name, state: state, reasons: reasons) if state == :incompatible

        state = manifest.metadata.to_h.fetch(:load_state, manifest.metadata.to_h["load_state"] || "failed").to_sym
        reasons << manifest.metadata.to_h.fetch(:load_message, manifest.metadata.to_h["load_message"] || "plugin did not load")
        return Status.new(name: manifest.name, state: state, reasons: reasons)
      end

      if manifest.validation_errors.any?
        state = :degraded
        reasons.concat(manifest.validation_errors)
      end

      if cycle_members.include?(manifest.name)
        state = :cycle
        cycle = cycles.find { |c| c.include?(manifest.name) }
        reasons << "participates in dependency cycle: #{cycle.join(' -> ')}"
      end

      # Unmet dependencies and conflicts only matter for a plugin that is on: a
      # disabled one is inert already, and calling it degraded filled boot logs
      # and the Plugins page with alarms about plugins nobody switched on.
      return Status.new(name: manifest.name, state: state, reasons: reasons) unless @enabled_names.include?(manifest.name)

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

    def declared_minimum(requirement)
      return unless requirement

      requirement.requirements.filter_map { |operator, version| version if %w[>= > = ~>].include?(operator) }.max
    end

    def canonical_cycle_key(cycle)
      nodes = cycle[0...-1]
      nodes.each_index.map { |index| nodes.rotate(index) }.min.join("\0")
    end
  end
end
