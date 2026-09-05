module Syrus
  # "This instance looks like it wants a plugin it does not have on."
  #
  # The third loading tier, and the reason it exists: `while_enabled` effects
  # need the plugin on, `always` effects need it to have been on once, and
  # neither can tell an admin about a plugin they have never touched. A plugin
  # nobody has enabled is exactly the one that needs to introduce itself.
  #
  # The contract that makes this safe is a placement rule rather than a
  # promise. A recommendation is declared in the manifest and may only reach
  # code under the plugin's `lib/`, which the gem requires at load time. It may
  # not touch the plugin's `app/` tree, which is Zeitwerk-managed and, for a
  # disabled plugin, deliberately never eager loaded. So a suggestion costs a
  # closure and whatever the block reads -- never the plugin.
  #
  #   suggests_enabling "Python repos get dependency audits and ruff/black" do |signals|
  #     signals.repositories_detecting("python")
  #   end
  #
  # The block returns evidence, and evidence is the whole point: "3 of your
  # repositories are Python" is actionable, "you might like this" is noise. A
  # falsy or empty return means no recommendation, which is the common case and
  # has to stay silent.
  module PluginRecommendations
    Recommendation = Data.define(:plugin, :reason, :evidence) do
      # A short, honest rendering of the evidence for the nudge itself. Lists
      # name a couple of examples rather than all of them: the admin needs to
      # recognize the signal, not audit it.
      def evidence_summary
        case evidence
        when Array then array_summary
        when Numeric then evidence.to_s
        else evidence.to_s
        end
      end

      private

      def array_summary
        shown = evidence.first(3).join(", ")
        evidence.length > 3 ? "#{shown} and #{evidence.length - 3} more" : shown
      end
    end

    @mutex = Mutex.new
    @suggestions = {}

    class << self
      # Registered from the manifest on every `to_prepare`, so re-registering a
      # name replaces rather than appends -- the same rule the plugin registry
      # itself follows for reloads.
      def register(plugin:, reason:, block:)
        @mutex.synchronize { @suggestions[plugin.to_s] = { reason: reason, block: block } }
      end

      def registered_plugin_names = @mutex.synchronize { @suggestions.keys.dup }

      def reset! = @mutex.synchronize { @suggestions = {} }

      # Removes one registration. Specs use it to clean up after themselves
      # without resetting the registry the running app is using.
      def deregister(name) = @mutex.synchronize { @suggestions.delete(name.to_s) }

      # Recommendations for every installed plugin that is currently off.
      #
      # An enabled plugin is never recommended, however loud its signal: the
      # admin has already answered the question, and re-asking is how a nudge
      # turns into a nag.
      def call(signals: PluginSignals.new)
        suggestions = @mutex.synchronize { @suggestions.dup }
        return [] if suggestions.empty?

        disabled_plugin_names.filter_map do |name|
          suggestion = suggestions[name]
          next unless suggestion

          evaluate(name, suggestion, signals)
        end
      end

      # The recommendation for one plugin, or nil. Used by the admin payload,
      # which already knows which plugin it is rendering.
      def for_plugin(name, signals: PluginSignals.new)
        call(signals: signals).find { |recommendation| recommendation.plugin == name.to_s }
      end

      private

      def disabled_plugin_names
        Syrus::PluginRegistry.all_plugins.reject(&:enabled?).map(&:name)
      rescue StandardError
        []
      end

      # One plugin's bad signal block must not cost the others their nudge, and
      # must certainly not cost the admin their page. This is the same
      # fail-open posture the rest of the plugin surface takes.
      def evaluate(name, suggestion, signals)
        evidence = suggestion[:block].call(signals)
        return nil if evidence.blank? && !evidence.is_a?(Numeric)
        return nil if evidence.is_a?(Numeric) && evidence.zero?
        return nil if evidence == true && suggestion[:reason].blank?

        Recommendation.new(plugin: name, reason: suggestion[:reason], evidence: evidence)
      rescue StandardError => e
        Rails.logger.warn("[plugin_recommendations] #{name}: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
