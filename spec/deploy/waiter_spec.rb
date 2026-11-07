# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::Waiter do
  let(:clock) { Deploy::Clock::Fake.new }
  let(:out) { StringIO.new }
  let(:waiter) do
    described_class.new(clock: clock, reporter: Deploy::Reporter.new(out: out, err: StringIO.new),
      dry_run: dry_run)
  end
  let(:dry_run) { false }

  it "returns as soon as the question answers converged" do
    calls = 0
    waiter.until(label: "rollout", timeout: 60) do
      calls += 1
      described_class.converged
    end

    expect(calls).to eq(1)
    expect(clock.slept).to be_empty
  end

  it "polls until it converges, sleeping between questions" do
    answers = [ described_class.pending, described_class.pending, described_class.converged ]
    waiter.until(label: "rollout", timeout: 600, poll: 5) { answers.shift }

    expect(clock.slept).to eq([ 5, 5 ])
  end

  # "This failed" and "this did not finish in time" send an operator to
  # different places. Reporting the second when the first happened sends them
  # looking for a hang that never occurred.
  it "distinguishes a failure from a timeout" do
    expect {
      waiter.until(label: "migrations", timeout: 600) do
        described_class.failed("the migration raised", detail: "stack trace")
      end
    }.to raise_error(Deploy::Failure, /migrations: the migration raised/) { |error|
      expect(error.detail).to eq("stack trace")
    }
  end

  it "times out with how long it waited and what it last saw" do
    expect {
      waiter.until(label: "rollout", timeout: 90, poll: 30) { described_class.pending("1/3 updated") }
    }.to raise_error(Deploy::Failure, /rollout: not finished after 1m30s \(1\/3 updated\)/)
  end

  it "runs a timeout hook so diagnostics are gathered once, on the failure path" do
    diagnosed = 0
    expect {
      waiter.until(label: "rollout", timeout: 10, poll: 5, on_timeout: ->(_) { diagnosed += 1 }) do
        described_class.pending
      end
    }.to raise_error(Deploy::Failure)

    expect(diagnosed).to eq(1)
  end

  # A phase with a long legitimate runtime is indistinguishable from a wedged
  # one if nothing is printed until the deadline, and that is exactly what made
  # a short migration timeout feel like the only safe setting.
  it "reports progress while it waits, less often than it polls" do
    answers = Array.new(20) { described_class.pending("migrating: AddIndexToRuns") }
    answers << described_class.converged

    waiter.until(label: "migrations", timeout: 600, poll: 5, report_every: 30) { answers.shift }

    # Polled 20 times across 100 seconds, reported three times.
    expect(out.string.scan("migrating: AddIndexToRuns").length).to eq(3)
  end

  describe "in a dry run" do
    let(:dry_run) { true }

    # Nothing in a dry run was created, so every wait would poll a resource
    # that does not exist until its own deadline -- which once turned a
    # ten-minute budget into ten minutes of hot spin.
    it "converges immediately without asking the question" do
      asked = false
      verdict = waiter.until(label: "rollout", timeout: 600) { asked = true; described_class.pending }

      expect(verdict).to be_converged
      expect(asked).to be(false)
    end

    it "says so, so a phase can skip work that has nothing to observe" do
      expect(waiter).to be_skip
    end
  end
end
