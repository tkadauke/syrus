module Steps
  class StateSynchronizer
    Result = Data.define(:synchronized, :reason, :run, :state) do
      def synchronized? = synchronized
    end

    def self.from_latest_terminal_run!(step, runs: nil)
      new(step, runs: runs).from_latest_terminal_run!
    end

    def initialize(step, runs: nil)
      @step = step
      @projection = StateProjection.for(step, runs: runs)
    end

    def from_latest_terminal_run!
      return result(false, "Step no longer exists") unless step
      return result(false, "Step is #{step.state}, not active") unless step.queued? || step.running?

      run = projection.latest_terminal_run
      return result(false, "Step has no terminal Run") unless run
      return result(false, "Step still has active Runs", run: run) if projection.active_run

      transition = transition_from(run)
      return transition unless transition.synchronized?

      step.save!
      result(true, "reconciled #{step.slug} to #{step.state} from #{run.slug}", run: run, state: step.state)
    end

    private

    attr_reader :step, :projection

    def transition_from(run)
      case run.state
      when "succeeded"
        return result(false, "Step cannot transition to succeeded", run: run) unless step.may_succeed?

        step.succeed!
      when "failed"
        return result(false, "Step cannot transition to failed", run: run) unless step.may_fail?

        step.fail!
      when "cancelled"
        return result(false, "Step cannot transition to cancelled", run: run) unless step.may_cancel?

        step.cancel!
      when "skipped"
        return result(false, "Step cannot transition to skipped", run: run) unless step.may_skip?

        step.skip!
      else
        return result(false, "Run is #{run.state}, not terminal", run: run)
      end

      result(true, "transitioned", run: run, state: step.state)
    end

    def result(synchronized, reason, run: nil, state: nil)
      Result.new(synchronized: synchronized, reason: reason, run: run, state: state)
    end
  end
end
