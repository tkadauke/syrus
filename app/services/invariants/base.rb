module Invariants
  # Shared shape of one invariant. Subclasses declare `DEFAULTS` (their
  # tunable thresholds) and implement `#violations`, reading only persisted
  # state and comparing times against `now`. They must never write.
  class Base
    DEFAULTS = {}.freeze

    def self.key = name.demodulize.underscore
    def self.defaults = self::DEFAULTS

    def self.call(now: Time.current, scope: Scope.all, **options)
      unknown = options.keys.map(&:to_sym) - defaults.keys
      raise ArgumentError, "unknown #{key} options: #{unknown.join(', ')}" if unknown.any?

      new(now: now, scope: scope, options: defaults.merge(options.symbolize_keys)).violations
    end

    def initialize(now:, scope:, options:)
      @now = now
      @scope = scope
      @options = options
    end

    def violations
      raise NotImplementedError
    end

    private

    attr_reader :now, :scope, :options

    def violation(**attrs)
      Violation.new(invariant: self.class.key, **attrs)
    end

    def older_than?(time, threshold)
      time.present? && time <= now - threshold
    end

    def hours_since(time)
      return nil unless time

      ((now - time) / 1.hour).round(1)
    end

    def job_ref(job)
      { id: job.id, slug: job.slug, state: job.state }
    end

    def iso(time) = time&.iso8601
  end
end
