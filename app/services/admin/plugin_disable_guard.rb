module Admin
  class PluginDisableGuard
    Blocker = Data.define(:kind, :label, :count)

    class Blocked < StandardError
      attr_reader :blockers

      def initialize(blockers)
        @blockers = blockers
        super(blockers.map(&:label).join(", "))
      end
    end

    def self.blockers_for(manifest)
      new(manifest).blockers
    end

    def self.ensure_disableable!(manifest)
      blockers = blockers_for(manifest)
      raise Blocked, blockers if blockers.any?
    end

    # Currently-enabled plugins that depend (transitively) on `manifest`. This is
    # a warn-and-confirm signal, not a hard block: disabling `manifest` is still
    # allowed, but the caller should confirm before cascading the disable through
    # these plugins too (see Api::V1::Admin::PluginsController#disable).
    def self.dependents_for(manifest)
      new(manifest).dependents
    end

    def initialize(manifest)
      @manifest = manifest
    end

    def blockers
      @blockers ||= begin
        result = []
        result.concat(agent_provider_blockers)
        result.concat(chat_provider_blockers)
        result.concat(input_source_blockers)
        result.concat(source_control_blockers)
        result
      end
    end

    def dependents
      @dependents ||= PluginDependencyGraph.new.dependents_for(manifest.name).select do |name|
        PluginRecord.find_by(name: name)&.effective_enabled?
      end
    end

    private

    attr_reader :manifest

    def agent_provider_blockers
      providers(:agent_provider).flat_map do |provider|
        key = provider.provider_key
        [
          blocker(:configured_users, "Configured users use #{provider.display_name}", User.where(agent_provider: key).count),
          blocker(:configured_repositories, "Configured repositories use #{provider.display_name}", Repository.where(agent_provider: key).count),
          blocker(:open_jobs, "Open jobs use #{provider.display_name}", Job.open_threads.where(agent_provider: key).count),
          blocker(:active_workflows, "Active workflows use #{provider.display_name}", WorkUnits::Ownership.active_workflow_count(agent_provider: key))
        ].compact
      end
    end

    def chat_provider_blockers
      providers(:chat_provider).flat_map do |provider|
        key = provider.provider_key
        [
          blocker(:configured_chats, "Chats are pinned to #{provider.display_name}", ChatSession.where(chat_provider: key).count),
          blocker(:configured_users, "Configured users use #{provider.display_name} for chat", User.where(chat_provider: key).count)
        ].compact
      end
    end

    def input_source_blockers
      providers(:input_source).filter_map do |provider|
        blocker(:configured_input_sources, "Configured input sources use #{provider.name}", InputSource.where(type: provider.name).count)
      end
    end

    def source_control_blockers
      providers(:source_control_provider).filter_map do |provider|
        next unless provider.respond_to?(:available_for?)

        count = Repository.active.count { |repository| provider.available_for?(repository) }
        blocker(:configured_repositories, "Repositories use #{provider.display_name} source-control operations", count)
      end
    end

    def providers(extension_point)
      Array(manifest.provides[extension_point])
    end

    def blocker(kind, label, count)
      count.positive? ? Blocker.new(kind: kind.to_s, label: label, count: count) : nil
    end
  end
end
