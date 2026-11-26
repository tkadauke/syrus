module Achievements
  module Callbacks
    include Syrus::Host::Callbacks

    # A bad definition set must not stop the instance from booting; it is
    # reported loudly instead. Evaluation work refuses unknown keys on its own.
    def self.on_boot
      problems = Achievements::Registry.default.problems
      return if problems.empty?

      Rails.logger.error("[achievements] invalid definition registry: #{problems.join('; ')}")
    end
  end
end
