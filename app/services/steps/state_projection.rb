module Steps
  class StateProjection
    ACTIVE_STATES = %w[ queued running ].freeze
    TERMINAL_STATES = %w[ succeeded failed cancelled skipped ].freeze

    def self.for(step, runs: nil) = new(step, runs: runs)

    def initialize(step, runs: nil)
      @step = step
      @runs = runs
    end

    def visible_state
      return running_run.state if running_run
      return latest_terminal_run.state if latest_terminal_run
      return queued_run.state if step.queued? && queued_run

      step.state
    end

    def active?
      ACTIVE_STATES.include?(visible_state)
    end

    def terminal?
      TERMINAL_STATES.include?(visible_state)
    end

    def latest_run
      ordered_runs.last
    end

    def active_run
      running_run || queued_run
    end

    def running_run
      ordered_runs.reverse.find { |run| run.state == "running" }
    end

    def queued_run
      ordered_runs.reverse.find { |run| run.state == "queued" }
    end

    def latest_terminal_run
      ordered_runs.reverse.find { |run| TERMINAL_STATES.include?(run.state) }
    end

    def drifted?
      visible_state != step.state
    end

    private

    attr_reader :step

    def ordered_runs
      @ordered_runs ||= begin
        rows = @runs || step.runs.to_a
        rows.sort_by { |run| [ run.created_at || Time.zone.at(0), run.id || 0 ] }
      end
    end
  end
end
