require "json"
require "time"
require_relative "worker_environment_smoke/shell"
require_relative "worker_environment_smoke/checks"
require_relative "worker_environment_smoke/formatter"

# Proves this worker can run the work Syrus routes to it, before it claims any.
#
# Capability probes answer "what is this worker" (os, arch, Xcode). This
# answers "does the toolchain behind it actually work": the CLIs a step shells
# out to start, a C extension compiles, mysql2 can find a MySQL client to build
# against, and the workflow data root supports the flock/hardlink/rename
# semantics workspaces rely on. Every one of those has broken under a running
# worker after an environment change, and each was found by jobs failing hours
# later instead of by the worker refusing the work.
#
# The report rides along with the worker's capability diagnostics (instance
# heartbeat, health samples), so it is recorded wherever capabilities are. A
# failed check fails closed for the work that needs that check only:
# RunQueueResolver stops choosing the worker for a step whose required checks
# (WorkerEnvironmentSmoke::Requirements) include a failure, and RunJob hands
# such a step back instead of starting it. A worker with no report, or a check
# it does not report, is treated as unknown rather than failed, so an older
# worker revision keeps taking work during a rollout.
#
# Checks are fast (a few seconds in total, run in parallel) and side-effect
# free: compiles happen in a private temp directory, and the data-root check
# creates and removes its own uniquely named scratch files.
#
# Self-contained on purpose: `bin/worker-environment-smoke` runs it without
# booting Rails so an operator, or a Mac release cutover, can check a host
# before a worker process ever starts. Rails-only inputs (plugin-contributed
# checks, the prepare env forward list) are resolved only when Rails is loaded.
class WorkerEnvironmentSmoke
  REPORT_VERSION = 1
  DIAGNOSTIC_KEY = "environment_smoke".freeze
  REFRESH_INTERVAL_SECONDS = 15 * 60
  PASSED = "passed".freeze
  FAILED = "failed".freeze
  # Some checks failed, none of them essential: the worker keeps taking the
  # work that does not need the failed checks.
  DEGRADED = "degraded".freeze

  # Mirrors Steps::Prepare::BASE_ENV_FORWARD: a check is only meaningful when
  # it runs with the environment the work it vouches for runs with. Inside
  # Rails the live list (including plugin-forwarded keys) is used instead.
  BASE_ENV_FORWARD = %w[
    HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE TZ HOSTNAME TMPDIR SHELL
    MISE_DATA_DIR
  ].freeze

  class << self
    # The report this process publishes. Computed once at boot (the first
    # capability snapshot) and refreshed by the heartbeat, so a repaired host
    # starts taking work again without a restart.
    def current
      @mutex ||= Mutex.new
      @mutex.synchronize { @current ||= new.call }
    end

    def refresh!
      report = new.call
      (@mutex ||= Mutex.new).synchronize { @current = report }
    end

    def refresh_if_stale!(now: Time.now)
      report = @current
      return refresh! if report.nil?

      observed = Time.iso8601(report["observed_at"].to_s) rescue nil
      return report if observed && now - observed < REFRESH_INTERVAL_SECONDS

      refresh!
    end

    def reset!
      @current = nil
    end

    # Only worker processes publish a report. Web pods do not run work, and
    # the test suite must not shell out to the real toolchain from every spec
    # that builds a capability snapshot.
    def publishable?(env: ENV)
      return false if env["SYRUS_WORKER_ENVIRONMENT_SMOKE"] == "0"
      return false if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?

      env.fetch("SYRUS_ROLE", "") == "worker"
    end

    # => names of checks this report says failed. A missing or malformed report
    # fails nothing: "unknown" must never read as "broken".
    def failed_checks(report)
      return [] unless report.is_a?(Hash)

      Array(report["failed"]).map(&:to_s)
    end

    # The failed checks among `required` -- what stops this worker from taking
    # a given step.
    def blocking_failures(report, required)
      failed_checks(report) & Array(required).map(&:to_s)
    end

    def failure_reasons(report, names)
      checks = report.is_a?(Hash) ? report["checks"].to_h : {}
      Array(names).to_h { |name| [ name, checks.dig(name, "reason").to_s ] }
    end

    def prepare_env_keys
      if defined?(Steps::Prepare) && Steps::Prepare.respond_to?(:prep_env_forward)
        Steps::Prepare.prep_env_forward
      else
        BASE_ENV_FORWARD
      end
    rescue StandardError
      BASE_ENV_FORWARD
    end

    def data_root(env: ENV)
      env["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus")
    end
  end

  def initialize(checks: nil, shell: Shell.new, env: ENV, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @shell = shell
    @env = env
    @clock = clock
    @checks = checks || Checks.default(env: env, data_root: self.class.data_root(env: env))
  end

  def call
    started = @clock.call
    child_env = child_environment
    results = @checks.map do |check|
      Thread.new { [ check.name, run_check(check, child_env) ] }
    end.map(&:value).to_h
    failed = results.select { |_name, result| result["status"] == FAILED }.keys.sort
    status = if failed.empty? then PASSED
    elsif failed.any? { |name| results.dig(name, "essential") } then FAILED
    else DEGRADED
    end

    {
      "version" => REPORT_VERSION,
      "status" => status,
      "observed_at" => Time.now.utc.iso8601,
      "duration_ms" => ((@clock.call - started) * 1000).round,
      "failed" => failed,
      "checks" => results
    }
  end

  private

  def run_check(check, child_env)
    started = @clock.call
    result = check.call(shell: @shell, env: child_env)
    result.merge("duration_ms" => ((@clock.call - started) * 1000).round)
  rescue StandardError => e
    { "status" => FAILED, "reason" => "check raised #{e.class}: #{e.message}", "duration_ms" => ((@clock.call - started) * 1000).round }
  end

  def child_environment
    self.class.prepare_env_keys.each_with_object({}) do |key, env|
      env[key] = @env[key] if @env[key]
    end
  end
end
