module Ruby
  class RspecGraderType
    include Syrus::Plugin::GraderType

    DEFAULT_TIMEOUT_MINUTES = 15
    FOCUSED_CHANGED_FILES = [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ].freeze

    def self.type_name
      "rspec"
    end

    def self.grade_steps(config:, default_failures:)
      new(config: config, default_failures: default_failures).grade_steps
    end

    def self.focused_command
      <<~'RUBY'.squish
        ruby -e 'base = %w[origin/main origin/master main master].find { |ref| system("git", "rev-parse", "--verify", "#{ref}^{commit}", out: File::NULL, err: File::NULL) }; abort("no base ref found for focused RSpec") unless base; changed = `git diff --name-only --diff-filter=ACMR #{base}...HEAD -- "*.rb"`.lines.map(&:strip); specs = changed.flat_map { |path| if path.start_with?("spec/") && path.end_with?("_spec.rb"); path; elsif path.start_with?("app/"); "spec/#{path.delete_prefix("app/").sub(/\.rb\z/, "_spec.rb")}"; elsif path.start_with?("lib/"); "spec/lib/#{path.delete_prefix("lib/").sub(/\.rb\z/, "_spec.rb")}"; end }.compact.uniq.select { |path| File.exist?(path) }; if specs.empty?; puts "No focused RSpec files matched changed Ruby files"; exit 0; end; exec("bundle", "exec", "rspec", *specs)'
      RUBY
    end

    def initialize(config:, default_failures:)
      @config = config.to_h.stringify_keys
      @default_failures = default_failures
    end

    def grade_steps
      [
        grade_step(name: full_name, run: "bundle exec rspec", phases: %w[landing ci]),
        grade_step(name: focused_name, run: focused_command, phases: %w[review], when_files_changed: FOCUSED_CHANGED_FILES)
      ]
    end

    private

    attr_reader :config, :default_failures

    def full_name
      config["name"].to_s.strip.presence || "rspec"
    end

    def focused_name
      "#{full_name}-focused"
    end

    def required?
      return true unless config.key?("required")

      ActiveModel::Type::Boolean.new.cast(config["required"])
    end

    def timeout_minutes
      raw = config["timeout_minutes"]
      return DEFAULT_TIMEOUT_MINUTES if raw.blank?

      minutes = Integer(raw)
      raise ArgumentError, "timeout_minutes must be positive" unless minutes.positive?

      [ minutes, 90 ].min
    rescue ArgumentError
      raise ArgumentError, "timeout_minutes must be a positive integer"
    end

    def failures
      config["failures"].to_s.strip.presence || "allow_inherited"
    end

    def base_retry
      SyrusYml::BaseRetry.new(strategy: "plugin", command: nil)
    end

    def grade_step(name:, run:, phases:, when_files_changed: nil)
      SyrusYml::GradeStep.new(
        name: name,
        run: run,
        ci: nil,
        phases: phases,
        description: nil,
        required: required?,
        timeout_minutes: timeout_minutes,
        when_files_changed: when_files_changed,
        junit_output: nil,
        failures: failures,
        base_retry: base_retry,
        deps: []
      )
    end

    def focused_command
      self.class.focused_command
    end
  end
end
