require "rails_helper"

RSpec.describe Syrus::EffectScope do
  subject(:scope) { described_class.new(label: "root") }

  it "runs installs immediately and their teardowns on dispose" do
    log = []
    scope.effect("a") { log << :installed_a; -> { log << :disposed_a } }

    expect(log).to eq([ :installed_a ])

    scope.dispose

    expect(log).to eq([ :installed_a, :disposed_a ])
  end

  # The last thing installed is the first thing undone, so a dependent unwinds
  # before whatever it was built on.
  it "disposes in reverse order" do
    log = []
    scope.effect("first") { -> { log << :first } }
    scope.effect("second") { -> { log << :second } }

    scope.dispose

    expect(log).to eq([ :second, :first ])
  end

  it "treats a nil return as nothing to undo" do
    expect { scope.effect("noop") { nil } }.not_to raise_error
    expect { scope.dispose }.not_to raise_error
  end

  # A teardown that is silently missing is invisible until a disable fails to
  # take effect, so a non-callable return is an error rather than a shrug.
  it "rejects a return value that is neither callable nor nil" do
    expect { scope.effect("bad") { :not_callable } }
      .to raise_error(ArgumentError, /must return a callable teardown or nil/)
  end

  it "disposes children before its own effects" do
    log = []
    child = scope.child(label: "child")
    child.effect("child_effect") { -> { log << :child } }
    scope.effect("parent_effect") { -> { log << :parent } }

    scope.dispose

    expect(log).to eq([ :child, :parent ])
  end

  it "keeps disposing after a teardown raises" do
    log = []
    scope.effect("ok") { -> { log << :ok } }
    scope.effect("boom") { -> { raise "teardown failed" } }

    expect { scope.dispose }.not_to raise_error
    expect(log).to eq([ :ok ])
  end

  it "is idempotent" do
    log = []
    scope.effect("once") { -> { log << :disposed } }

    2.times { scope.dispose }

    expect(log).to eq([ :disposed ])
  end

  it "refuses new effects once disposed" do
    scope.dispose

    expect { scope.effect("late") { -> {} } }.to raise_error(described_class::DisposedScope)
    expect { scope.child(label: "late") }.to raise_error(described_class::DisposedScope)
  end
end
