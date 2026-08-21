module Ruby
  # :prepare_detector for plain Ruby repositories: a Gemfile at the repo
  # root means `bundle install` should run before the agent starts.
  # Matches the signal RepoPrepPlan::AUTO_DETECT used to hardcode for
  # Ruby/Rails repos.
  class PrepareDetector
    SPAN_LABELS = [
      [ /\bbundle\s+check\b/, "bundle check" ],
      [ /\bbundle\s+install\b/, "bundle install" ],
      [ /\b(?:bin\/rails|rails)\s+db:test:prepare\b/, "db:test:prepare" ],
      [ /\b(?:bin\/)?rspec\b/, "rspec" ],
      [ /\b(?:bin\/)?rubocop\b/, "rubocop" ]
    ].freeze

    def self.detect?(repo_path)
      Pathname.new(repo_path).join("Gemfile").exist?
    end

    def self.prepare_commands(repo_path)
      [ "bundle install" ]
    end

    def self.mise_version_file
      ".ruby-version"
    end

    def self.span_labels
      SPAN_LABELS
    end
  end
end
