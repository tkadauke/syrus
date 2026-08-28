#!/usr/bin/env ruby
# frozen_string_literal: true

# Manual eval harness entry point -- see evals/README.md. Not wired into
# CI or bin/rspec: run it by hand with `bin/eval [scenario_slug ...]`.
require_relative "../config/environment"
require_relative "lib/evals"

ok = Evals::CLI.new(ARGV).run
exit(ok ? 0 : 1)
