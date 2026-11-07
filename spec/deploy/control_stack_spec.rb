# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::ControlStack do
  let(:err) { StringIO.new }
  let(:stack) { described_class.new(reporter: Deploy::Reporter.new(out: StringIO.new, err: err)) }

  # Registering an undo next to the thing it undoes makes the ordering
  # structural: Flux is suspended first, so it is resumed last, because a stack
  # says so rather than because someone kept a cleanup function in agreement
  # with the order the phases happen to run in.
  it "unwinds in reverse order of registration" do
    order = []
    stack.push("flux") { order << "flux" }
    stack.push("cronjob") { order << "cronjob" }
    stack.push("migration job") { order << "migration job" }

    stack.unwind

    expect(order).to eq([ "migration job", "cronjob", "flux" ])
  end

  # Leaving Flux suspended because a cronjob patch failed is how a cluster
  # stops reconciling for a weekend.
  it "keeps unwinding after an undo raises, and says which one failed" do
    order = []
    stack.push("flux") { order << "flux" }
    stack.push("cronjob") { raise "the API server said no" }

    stack.unwind

    expect(order).to eq([ "flux" ])
    expect(err.string).to include("could not restore cronjob: the API server said no")
  end

  # Some work is more dangerous to interrupt than to leave running. The only
  # thing that can judge that is the undo itself, looking at live state at the
  # moment of unwinding.
  it "lets an undo decline, and reports why" do
    stack.push("migration job/x") do
      raise described_class::Decline, "it is still applying migrations"
    end

    stack.unwind

    expect(err.string).to include("left migration job/x in place: it is still applying migrations")
  end

  it "forgets work whose undo is no longer wanted" do
    ran = []
    stack.push("cronjob") { ran << "cronjob" }
    stack.discharge("cronjob")

    stack.unwind

    expect(ran).to be_empty
    expect(stack).to be_empty
  end

  it "unwinds only once, however many times it is asked" do
    count = 0
    stack.push("flux") { count += 1 }

    stack.unwind
    stack.unwind

    expect(count).to eq(1)
  end

  it "names what is still outstanding" do
    stack.push("flux") { }
    stack.push("cronjob") { }

    expect(stack.pending).to eq([ "flux", "cronjob" ])
  end
end
