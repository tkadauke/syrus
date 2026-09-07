module Syrus
  module Plugin
    # Interface module for Runtime Session provider implementations (DOC-17).
    #
    # A Runtime Session is a live process, app, device, emulator, or service
    # stack attached to a Coding Mode workspace. Plugins register a provider
    # per platform (browser, iOS simulator, Android emulator, ...); core owns
    # the RuntimeSession record, lifecycle, and sidebar rendering.
    #
    # `provider_key`, `display_name`, `detect`, and `capabilities` are class
    # methods so a provider can be selected for a repository/config before any
    # session exists. The remaining lifecycle methods are instance methods,
    # called on a provider instance scoped to one running session.
    #
    # Include this module in any class registered as a :runtime_session_provider
    # extension point:
    #
    #   class MyPlugin::RuntimeSessionProvider
    #     include Syrus::Plugin::RuntimeSessionProvider
    #
    #     def self.provider_key = "browser"
    #     def self.display_name = "Browser"
    #     def self.detect(repository, config) = ...
    #     def self.capabilities(repository, config) = ...
    #
    #     def start_session(workspace_ref, config) = ...
    #     def build_or_reload(session_id, options) = ...
    #     def launch(session_id, options) = ...
    #     def snapshot(session_id, options) = ...
    #     def inspect(session_id, options) = ...
    #     def input(session_id, event) = ...
    #     def logs(session_id, cursor, options) = ...
    #     def stop_session(session_id) = ...
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { runtime_session_provider: MyPlugin::RuntimeSessionProvider }
    #   )
    module RuntimeSessionProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def provider_key
          raise NotImplementedError, "#{self}.provider_key is required"
        end

        def display_name
          raise NotImplementedError, "#{self}.display_name is required"
        end

        # Whether this provider applies to the given repository/config.
        # Returns a truthy detection result (or nil/false when the provider
        # does not apply).
        def detect(_repository, _config)
          raise NotImplementedError, "#{self}.detect is required"
        end

        # The RuntimeCapability hash this provider can offer for the given
        # repository/config (stream/input/inspect/build/artifacts kinds).
        def capabilities(_repository, _config)
          raise NotImplementedError, "#{self}.capabilities is required"
        end
      end

      # -- Interface methods providers must implement --

      # Starts a new session for the given workspace, returning enough
      # provider-specific state for core to persist on the RuntimeSession
      # record (e.g. metadata).
      def start_session(_workspace_ref, _config)
        raise NotImplementedError, "#{self.class}#start_session is required"
      end

      # Builds or reloads the running target (e.g. restart a dev server,
      # recompile, hot-reload).
      def build_or_reload(_session_id, _options)
        raise NotImplementedError, "#{self.class}#build_or_reload is required"
      end

      # Launches (or relaunches) the target app/process/device inside the
      # session.
      def launch(_session_id, _options)
        raise NotImplementedError, "#{self.class}#launch is required"
      end

      # Captures a point-in-time view of the session (e.g. a screenshot).
      def snapshot(_session_id, _options)
        raise NotImplementedError, "#{self.class}#snapshot is required"
      end

      # Returns a structural inspection of the session's target (e.g. DOM,
      # accessibility tree, view hierarchy).
      #
      # Named `inspect` to match DOC-17's RuntimeSessionProvider interface,
      # which shadows Kernel#inspect. Arguments default to nil so anything
      # that calls plain `#inspect` (RSpec failure output, pry, logging)
      # gets a NotImplementedError instead of an ArgumentError.
      def inspect(_session_id = nil, _options = nil)
        raise NotImplementedError, "#{self.class}#inspect is required"
      end

      # Delivers an input event (pointer, keyboard, touch, stdin, ...) to the
      # session's target.
      def input(_session_id, _event)
        raise NotImplementedError, "#{self.class}#input is required"
      end

      # Returns the next chunk of log output after `cursor`.
      def logs(_session_id, _cursor, _options)
        raise NotImplementedError, "#{self.class}#logs is required"
      end

      # Tears down the underlying process/device/VM lease for the session.
      def stop_session(_session_id)
        raise NotImplementedError, "#{self.class}#stop_session is required"
      end
    end
  end
end
