class WorkerEnvironmentSmoke
  # Plain-text rendering of a report for the operator CLIs, in the
  # `OK   ...` / `WARN ...` / `FAIL ...` shape bin/macos-worker-check prints.
  # An essential check (one every Run needs) that failed is FAIL; any other
  # failed check is WARN -- the worker still takes the work that does not
  # need it.
  module Formatter
    module_function

    def lines(report)
      checks = report.to_h["checks"].to_h
      rows = checks.sort.map do |name, result|
        if result["status"] == PASSED
          "OK   #{name}#{result['detail'] ? ": #{result['detail']}" : ''}"
        elsif result["essential"]
          "FAIL #{name}: #{result['reason']}"
        else
          "WARN #{name}: #{result['reason']} (work that needs it is routed elsewhere)"
        end
      end
      rows << "worker-environment-smoke: #{report['status']} (#{report['duration_ms']} ms)" \
        "#{report['failed'].to_a.empty? ? '' : "; failed: #{report['failed'].join(', ')}"}"
      rows
    end
  end
end
