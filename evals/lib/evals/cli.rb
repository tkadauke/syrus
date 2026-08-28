require "optparse"

module Evals
  class CLI
    class UsageError < StandardError; end

    def initialize(argv)
      @options = { provider: nil, user: nil, verbose: false, keep_workspace: false, list: false, results_path: ResultStore::HISTORY_PATH }
      @slugs = parse!(argv.dup)
    rescue UsageError => e
      @parse_error = e
    end

    def run
      raise @parse_error if @parse_error
      return list_scenarios if @options[:list]

      scenarios = @slugs.any? ? @slugs.map { |slug| Scenarios.load(slug) } : Scenarios.all
      abort("No scenarios found under evals/scenarios/.") if scenarios.empty?

      user = resolve_user!
      provider = (@options[:provider] || user.agent_provider).to_s
      unless user.agent_provider_configured?(provider)
        abort("User #{user.id} has no credentials configured for agent provider #{provider.inspect}.")
      end

      results = scenarios.map { |scenario| run_scenario(scenario, user: user, provider: provider) }
      print_summary(results)
      results.all? { |r| r.passed && r.history_intact && r.verifier_error.blank? && r.agent_error.blank? }
    rescue UsageError => e
      warn "evals: #{e.message}"
      warn ""
      warn usage
      false
    end

    private

    def parse!(argv)
      OptionParser.new do |opts|
        opts.banner = usage
        opts.on("--list", "List available scenarios and exit") { @options[:list] = true }
        opts.on("--provider=PROVIDER", "Agent provider to use (default: the user's configured provider)") { |v| @options[:provider] = v }
        opts.on("--user=ID_OR_EMAIL", "User whose credentials to run the agent as (default: $SYRUS_EVAL_USER)") { |v| @options[:user] = v }
        opts.on("--keep-workspace", "Don't delete the scratch fixture workspace after the run (for debugging)") { @options[:keep_workspace] = true }
        opts.on("--results-path=PATH", "Where to append result history (default: evals/results/history.jsonl)") { |v| @options[:results_path] = v }
        opts.on("-v", "--verbose", "Stream agent output while it runs") { @options[:verbose] = true }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end.parse!(argv)
      argv
    rescue OptionParser::InvalidOption => e
      raise UsageError, e.message
    end

    def usage
      "Usage: bin/eval [options] [scenario_slug ...]\n\n" \
      "Runs one or more evals/scenarios/* pressure scenarios against a real agent\n" \
      "and records pass/fail history. With no scenario_slug given, runs all of them.\n" \
      "See evals/README.md."
    end

    def list_scenarios
      Scenarios.all.each do |scenario|
        puts "#{scenario.slug}"
        puts "    target: #{scenario.target}"
        puts "    #{scenario.description}" if scenario.description.present?
      end
      true
    end

    def resolve_user!
      identifier = @options[:user] || ENV["SYRUS_EVAL_USER"]
      raise UsageError, "no --user given and $SYRUS_EVAL_USER is unset -- pass a user id or email" if identifier.blank?

      user = identifier.match?(/\A\d+\z/) ? User.find_by(id: identifier) : User.find_by(email_address: identifier)
      raise UsageError, "no user found for #{identifier.inspect}" unless user

      user
    end

    def run_scenario(scenario, user:, provider:)
      puts "==> #{scenario.slug} (#{scenario.target})"
      workspace_path = FixtureWorkspace.build(scenario)
      log_sink = @options[:verbose] ? ->(chunk, **) { print chunk } : ->(*, **) {}

      run_result = AgentRun.call(scenario: scenario, workspace_path: workspace_path, user: user, provider: provider, log_sink: log_sink)
      agent_error = agent_error_for(run_result)
      verdict = Verifier.call(scenario: scenario, run_result: run_result, user: user, provider: provider)

      result = ScenarioResult.new(
        scenario_slug: scenario.slug,
        scenario_name: scenario.name,
        target: scenario.target,
        provider: provider,
        passed: verdict.passed,
        rationale: verdict.rationale,
        verifier_error: verdict.error,
        history_intact: run_result.history_intact,
        agent_error: agent_error,
        cost_usd: run_result.cost_usd,
        turns: run_result.turns,
        ran_at: Time.now.utc.iso8601
      )
      ResultStore.append(result, path: @options[:results_path])
      report(result)
      result
    rescue StandardError => e
      result = ScenarioResult.new(
        scenario_slug: scenario.slug, scenario_name: scenario.name, target: scenario.target,
        provider: provider, passed: false, rationale: nil, verifier_error: nil,
        history_intact: false, agent_error: "#{e.class}: #{e.message}",
        cost_usd: nil, turns: nil, ran_at: Time.now.utc.iso8601
      )
      ResultStore.append(result, path: @options[:results_path])
      report(result)
      result
    ensure
      FixtureWorkspace.cleanup(workspace_path) unless @options[:keep_workspace] || workspace_path.nil?
      puts "    workspace kept at #{workspace_path}" if @options[:keep_workspace] && workspace_path
    end

    def agent_error_for(run_result)
      return "timed out" if run_result.timed_out
      return "agent reported #{run_result.outcome || 'error'}" if run_result.is_error
      nil
    end

    def report(result)
      overall = result.passed && result.history_intact && result.verifier_error.blank? && result.agent_error.blank?
      puts "    #{overall ? 'PASS' : 'FAIL'}"
      puts "    agent_error: #{result.agent_error}" if result.agent_error
      puts "    history_intact: false" unless result.history_intact
      puts "    verifier_error: #{result.verifier_error}" if result.verifier_error.present?
      puts "    rationale: #{result.rationale}" if result.rationale.present?
    end

    def print_summary(results)
      puts ""
      puts "==== summary ===="
      results.each do |r|
        overall = r.passed && r.history_intact && r.verifier_error.blank? && r.agent_error.blank?
        puts "#{overall ? 'PASS' : 'FAIL'}  #{r.scenario_slug}"
      end
      puts "results appended to #{@options[:results_path]}"
    end
  end
end
