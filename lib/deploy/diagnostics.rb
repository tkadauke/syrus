# frozen_string_literal: true

module Deploy
  # What to print when a rollout will not converge.
  #
  # Gathered in one place, and only on the failure path, because this is a lot
  # of output -- describing every pod and tailing every log is the right amount
  # of information when a deploy has stopped and far too much when it is merely
  # slow. The progress reports during a wait are the other half of that
  # balance.
  class Diagnostics
    attr_reader :context

    def initialize(context)
      @context = context
    end

    def summarise(target)
      lines = [ "#{label}: #{target} has not converged" ]
      lines << kubectl.read("get", target, "-o", "wide").out

      selector = selector_for(target)
      if selector.nil?
        lines << "#{label}: could not derive a pod selector for #{target}"
        return lines.join("\n")
      end

      lines << "#{label}: pods for #{target}"
      lines << kubectl.read("get", "pods", "-l", selector, "-o", "wide").out
      lines << "#{label}: warning events"
      lines << kubectl.events(limit: 20, warnings_only: true)
      lines.join("\n")
    end

    def describe(target)
      selector = selector_for(target)
      lines = [ summarise(target) ]
      return lines.join("\n") if selector.nil?

      lines << "#{label}: recent events"
      lines << kubectl.events(limit: 80)
      lines << "#{label}: describe pods for #{target}"
      lines << kubectl.describe("pods", "-l", selector)
      lines << "#{label}: recent logs for #{target}"
      lines << kubectl.logs("-l", selector, tail: 120)
      lines.join("\n")
    end

    private

    # Syrus's workloads select on `name`; some select on `app`. Try both rather
    # than reconstructing the whole matchLabels map, which would also match
    # pods of a different revision in ways that make the diagnosis noisier.
    def selector_for(target)
      %w[name app].each do |key|
        value = kubectl.jsonpath(target, "{.spec.selector.matchLabels.#{key}}")
        return "#{key}=#{value}" unless value.empty?
      end
      nil
    end

    def kubectl = context.kubectl
    def label = context.label
  end
end
