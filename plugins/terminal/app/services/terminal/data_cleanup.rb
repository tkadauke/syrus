module Terminal
  # What used to be `User has_many :terminal_sessions, dependent: :destroy`,
  # injected onto the core model at boot.
  #
  # Installed with `always`, not `while_enabled`: disabling the plugin stops
  # new sessions being opened, it does not delete the rows already recorded,
  # and those still have to go when their user does.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("user terminal sessions") do
        Syrus::DataCleanup.register("User", "terminal.sessions") do |user|
          Terminal::Session.where(user_id: user.id).find_each(&:destroy)
        end
      end
    end
  end
end
