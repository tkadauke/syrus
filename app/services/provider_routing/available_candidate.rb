module ProviderRouting
  # Availability-aware wrapper around Resolver: walks the resolver's
  # ordered candidate list for a job/task_key and returns the first
  # candidate that is not paused/circuit-open/usage-exhausted (see
  # AvailabilityCheck). When every candidate is currently unavailable,
  # returns the top (most preferred) candidate anyway with `available:
  # false` so callers can still apply their existing pause-and-backoff
  # behavior against it, the same shape a "no failover found" result left
  # callers to do before this resolver existed.
  class AvailableCandidate
    Result = Data.define(:candidate, :candidates, :available) do
      def available? = available
    end

    def self.call(job:, task_key:, now: Time.current)
      new(job: job, task_key: task_key, now: now).call
    end

    def initialize(job:, task_key:, now: Time.current)
      @job = job
      @task_key = task_key
      @now = now
    end

    def call
      candidates = Resolver.call(job: job, task_key: task_key)
      return Result.new(candidate: nil, candidates: candidates, available: false) if candidates.blank?

      candidates.each do |candidate|
        next if candidate.provider.blank?

        availability = availability_for(candidate.provider)
        if AvailabilityCheck.available_enough?(user: user, provider: candidate.provider, availability: availability)
          return Result.new(candidate: candidate, candidates: candidates, available: true)
        end
      end

      Result.new(candidate: candidates.first, candidates: candidates, available: false)
    end

    private

    attr_reader :job, :task_key, :now

    def user
      @user ||= job.owner_user || job.user
    end

    def availability_for(provider)
      refresh_stale_usage(provider)
      App::ProviderAvailability.for_user(user, provider, now: now)
    end

    def refresh_stale_usage(provider)
      AgentProviders.for(provider).refresh_stale_usage!(user: user, now: now)
    rescue AgentProviders::ConfigurationError
      nil
    end
  end
end
