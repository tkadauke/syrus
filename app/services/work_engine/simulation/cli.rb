# frozen_string_literal: true

require "pathname"
require "yaml"

module WorkEngine
  module Simulation
    class Cli
      DEFAULT_SCENARIO_PATH = Rails.root.join("spec/fixtures/work_engine_simulations")

      def self.call(...) = new(...).call

      def initialize(argv:, out: $stdout, err: $stderr)
        @argv = Array(argv)
        @out = out
        @err = err
        @max_ticks = nil
      end

      def call
        options = parse_options
        return run_fuzz(options) if options[:fuzz]

        paths = scenario_paths(options[:paths])
        return usage(2) unless paths

        failures = []
        paths.each do |path|
          result = run_scenario(path)
          expected_status = expected_status_for(path)
          matched = status_matches?(result, expected_status, path)
          print_result(result, expected_status: expected_status, matched: matched)
          failures << result unless matched
        end

        if failures.empty?
          out.puts "work-engine simulations passed (#{paths.count} scenarios)"
          0
        else
          err.puts "work-engine simulations failed (#{failures.count}/#{paths.count} scenarios)"
          1
        end
      rescue ArgumentError => e
        err.puts e.message
        usage(2)
      end

      private

      attr_reader :argv, :out, :err
      attr_accessor :max_ticks

      def parse_options
        args = argv.dup
        options = { fuzz: false, shrink: true, paths: [] }
        while (arg = args.shift)
          case arg
          when "--max-ticks" then self.max_ticks = integer_option(arg, args)
          when "--fuzz" then options[:fuzz] = true
          when "--seed" then options[:seed] = integer_option(arg, args)
          when "--iterations" then options[:iterations] = integer_option(arg, args)
          when "--iteration" then options[:iteration] = integer_option(arg, args)
          when "--no-shrink" then options[:shrink] = false
          else options[:paths] << arg
          end
        end
        options
      end

      def integer_option(name, args)
        Integer(args.shift || raise(ArgumentError, "missing value for #{name}"))
      end

      def scenario_paths(args)
        return nil if args.length > 1

        expand_scenario_paths(args.first)
      end

      def expand_scenario_paths(arg)
        path = Pathname(arg.presence || DEFAULT_SCENARIO_PATH).expand_path(Rails.root)
        if path.directory?
          path.children.select { |child| child.file? && child.extname.in?(%w[.yml .yaml]) }.sort_by(&:to_s)
        elsif path.file?
          [ path ]
        else
          raise ArgumentError, "simulation scenario not found: #{path}"
        end
      end

      def run_fuzz(options)
        paths = (options[:paths].presence || [ nil ]).flat_map { |arg| expand_scenario_paths(arg) }.uniq
        _iterations, failures = WorkEngine::Simulation::Fuzz::Fuzzer.call(
          paths: paths,
          seed: options.fetch(:seed, WorkEngine::Simulation::Fuzz::DEFAULT_SEED),
          iterations: options.fetch(:iterations, WorkEngine::Simulation::Fuzz::DEFAULT_ITERATIONS),
          only_iteration: options[:iteration],
          shrink: options[:shrink],
          out: out
        )
        failures.empty? ? 0 : 1
      end

      def run_scenario(path)
        WorkEngine::Simulation::ScenarioExecution.call(path: path, max_ticks: max_ticks)
      rescue => e
        error_result(path, e)
      end

      def error_result(path, error)
        WorkEngine::Simulation::Result.new(
          scenario: scenario_name_for(path),
          ticks: 0,
          status: "error",
          events: [],
          stuck_reasons: [ "#{error.class}: #{error.message}", *Array(error.backtrace).first(5) ],
          wait_reasons: [],
          job_ids: [],
          epic_ids: [],
          work_intent_ids: []
        )
      end

      def scenario_name_for(path)
        YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false).to_h.fetch("name", nil).presence || path.basename.to_s
      rescue StandardError
        path.basename.to_s
      end

      def expected_status_for(path)
        status = YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false)
          .to_h
          .fetch("expected_status", nil)
          .presence
        status ? Array(status).map(&:to_s) : %w[success waiting]
      end

      # A fuzzer reproduction (it carries a `fuzz:` block) is judged the way
      # the fuzzer judged it, so it fails exactly while the bug reproduces.
      def status_matches?(result, expected_status, path = nil)
        if path && fuzz_reproduction?(path)
          return WorkEngine::Simulation::Fuzz::Oracle.failure_signature(result, expected_statuses: expected_status).nil?
        end

        expected_status.include?(result.status)
      end

      def fuzz_reproduction?(path)
        YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false).to_h.key?("fuzz")
      rescue StandardError
        false
      end

      def print_result(result, expected_status:, matched:)
        stream = matched ? out : err
        expectation = expected_status.join("|")
        stream.puts "#{result.scenario}: #{result.status} after #{result.ticks} ticks (expected #{expectation})"
        (ENV["SIMULATOR_FULL_LOG"].present? ? result.events : result.events.last(20)).each { |event| stream.puts "  #{event}" }
        if result.waiting?
          stream.puts "waiting:"
          result.wait_reasons.each { |reason| stream.puts "  #{reason}" }
        elsif result.stuck?
          stream.puts "stuck:"
          result.stuck_reasons.each { |reason| stream.puts "  #{reason}" }
        elsif result.violated?
          stream.puts "invariant violated:"
          result.stuck_reasons.each { |reason| stream.puts "  #{reason}" }
        elsif result.error?
          stream.puts "error:"
          result.stuck_reasons.each { |reason| stream.puts "  #{reason}" }
        end
      end

      def usage(status)
        stream = status.zero? ? out : err
        stream.puts "usage: bin/simulator [--max-ticks N] [path/to/scenario.yml|path/to/scenario_dir]"
        stream.puts "       bin/simulator --fuzz [--seed N] [--iterations K] [--iteration I] [--no-shrink] [scenario_or_dir...]"
        stream.puts "       bin/simulator # runs #{DEFAULT_SCENARIO_PATH.relative_path_from(Rails.root)}"
        status
      end
    end
  end
end
