module PluginRuntime
  # Services an operator stopped from the admin page. Reconciling would
  # otherwise start them again within a minute -- Ensure starts a stopped
  # container -- so the reconciler leaves a held service alone until the
  # operator starts or restarts it.
  #
  # Stored on this plugin's PluginRecord config, beside the settings form's
  # "settings" key (which saving that form merges without touching this), so
  # a hold survives restarts and is shared by web and worker.
  module Holds
    KEY = "held_services".freeze

    module_function

    def all
      Array(record&.config.to_h[KEY]).map(&:to_s)
    end

    def held?(name)
      all.include?(name.to_s)
    end

    def hold!(name)
      update { |names| names | [ name.to_s ] }
    end

    def release!(name)
      update { |names| names - [ name.to_s ] }
    end

    # Forget holds on services no plugin wants any more, so a plugin disabled
    # while its service was stopped comes back running when re-enabled.
    def prune!(wanted_names)
      wanted = wanted_names.map(&:to_s)
      update { |names| names & wanted } if (all - wanted).any?
    end

    def update
      rec = record
      return [] unless rec

      rec.with_lock do
        names = yield(Array(rec.config.to_h[KEY]).map(&:to_s)).uniq.sort
        rec.update!(config: rec.config.to_h.merge(KEY => names))
        names
      end
    end

    def record
      PluginRecord.find_by(name: "plugin_runtime")
    end
  end
end
