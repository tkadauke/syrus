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
        @max_ticks = DEFAULT_MAX_TICKS
      end

      def call
        paths = scenario_paths
        return usage(2) unless paths

        failures = []
        paths.each do |path|
          result = run_scenario(path)
          expected_status = expected_status_for(path)
          matched = status_matches?(result, expected_status)
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

      def scenario_paths
        args = argv.dup
        if args.first == "--max-ticks"
          args.shift
          self.max_ticks = Integer(args.shift || raise(ArgumentError, "missing value for --max-ticks"))
        end
        return nil if args.length > 1

        path = Pathname(args.first.presence || DEFAULT_SCENARIO_PATH).expand_path(Rails.root)
        if path.directory?
          path.children.select { |child| child.file? && child.extname.in?(%w[.yml .yaml]) }.sort_by(&:to_s)
        elsif path.file?
          [ path ]
        else
          raise ArgumentError, "simulation scenario not found: #{path}"
        end
      end

      def run_scenario(path)
        result = nil
        ActiveRecord::Base.transaction do
          result = WorkEngine::Simulation::ScenarioRunner.call(path: path, max_ticks: max_ticks)
          raise ActiveRecord::Rollback
        end
        result
      end

      def expected_status_for(path)
        status = YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false)
          .to_h
          .fetch("expected_status", nil)
          .presence
        status ? Array(status).map(&:to_s) : %w[success waiting]
      end

      def status_matches?(result, expected_status)
        expected_status.include?(result.status)
      end

      def print_result(result, expected_status:, matched:)
        stream = matched ? out : err
        expectation = expected_status.join("|")
        stream.puts "#{result.scenario}: #{result.status} after #{result.ticks} ticks (expected #{expectation})"
        result.events.last(20).each { |event| stream.puts "  #{event}" }
        if result.waiting?
          stream.puts "waiting:"
          result.wait_reasons.each { |reason| stream.puts "  #{reason}" }
        elsif result.stuck?
          stream.puts "stuck:"
          result.stuck_reasons.each { |reason| stream.puts "  #{reason}" }
        end
      end

      def usage(status)
        stream = status.zero? ? out : err
        stream.puts "usage: bin/simulator [--max-ticks N] [path/to/scenario.yml|path/to/scenario_dir]"
        stream.puts "       bin/simulator # runs #{DEFAULT_SCENARIO_PATH.relative_path_from(Rails.root)}"
        status
      end
    end
  end
end
