module Ruby
  # :prepare_detector for plain Ruby repositories: a Gemfile at the repo
  # root means `bundle install` should run before the agent starts.
  # Matches the signal RepoPrepPlan::AUTO_DETECT used to hardcode for
  # Ruby/Rails repos.
  class PrepareDetector
    SIGNALS = [
      [ "Gemfile", "bundle install" ]
    ].freeze

    def self.detect?(repo_path)
      Pathname.new(repo_path).join("Gemfile").exist?
    end

    def self.prepare_commands(repo_path)
      [ "bundle install" ]
    end

    def self.signals
      SIGNALS
    end
  end
end
