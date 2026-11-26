module Achievements
  # Retention contract for plugin-owned rows, installed with `always` so it
  # still applies while the plugin is disabled:
  #
  # - Destroying a User removes the unlocks attributed to that user and every
  #   acknowledgment that user recorded (including acknowledgments of instance
  #   unlocks). Instance unlocks themselves survive: they are canonical for the
  #   installation, not for a person.
  # - A Job or Epic subject is a weak reference. Jobs and Epics do not run
  #   plugin cleanup when destroyed, and this plugin does not add callbacks to
  #   core models, so the unlock and its bounded evidence outlive the subject and
  #   readers must tolerate a subject that no longer resolves.
  # - Unlocks are never aged out: they are history, not telemetry.
  # - Purging the plugin drops its tables (Syrus::PluginPurge); it holds no data
  #   outside the database, so no purge contributor is needed.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("user unlocks and acknowledgments") do
        Syrus::Host::DataCleanup.register("User", "achievements.user_data") do |user|
          Achievements::Acknowledgment.where(user_id: user.id).delete_all
          Achievements::Unlock.for_user(user.id).find_each(&:destroy)
        end
      end
    end
  end
end
