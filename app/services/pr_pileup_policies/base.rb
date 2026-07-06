module PrPileupPolicies
  class Base
    def initialize(task, fire_service:)
      @task = task
      @fire_service = fire_service
    end

    # Returns a ScheduledTaskFire::Result if the policy aborts the fire, nil if it should proceed.
    def check_pileup
      raise NotImplementedError
    end

    private

    attr_reader :task, :fire_service
  end
end
