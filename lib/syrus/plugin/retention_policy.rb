module Syrus
  module Plugin
    # Interface for `:retention_policy` extension points. A plugin gem that
    # owns a prunable DB table implements this to contribute its own
    # RetentionPolicyRegistry::Definition entries — keeping core's
    # RetentionPolicyRegistry free of any plugin-specific class names, so a
    # plugin stays physically removable (see bin/plugin-boundary-audit and
    # CLAUDE.md's "core specs must not enumerate plugin-provided things" rule)
    # instead of an undeletable core registry entry.
    #
    # Implementations must define:
    #
    #   retention_definitions -> Array<RetentionPolicyRegistry::Definition>
    #     One entry per prunable table this plugin owns. RetentionPolicyRegistry
    #     merges these into its own core entries on every read, using
    #     Syrus::PluginRegistry.all_plugins (not the enabled-filtered
    #     providers_for), so the backing AppSetting column and its
    #     admin-editable validation/metadata exist regardless of whether the
    #     plugin is currently enabled — the column persists and the model's
    #     `.prunable`-style scope is simply inert while the plugin is off,
    #     matching how other plugin-owned AppSettings behave.
    #
    # Register an implementation at boot time:
    #   provides retention_policy: "MyPlugin::RetentionPolicy"
    module RetentionPolicy
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def retention_definitions
          raise NotImplementedError, "#{self}.retention_definitions is required"
        end
      end
    end
  end
end
