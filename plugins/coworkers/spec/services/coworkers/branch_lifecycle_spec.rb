require "rails_helper"

RSpec.describe Coworkers::BranchLifecycle do
  class FakeBranchRemote
    attr_reader :operations
    attr_accessor :fail_copy, :fail_delete

    def initialize = @operations = []

    def copy!(from:, to:, coworker:)
      operations << [ :copy, from, to, coworker.id ]
      raise "copy failed" if fail_copy
    end

    def delete!(branch, **)
      operations << [ :delete, branch ]
      raise "delete failed" if fail_delete == branch
    end
  end

  let(:coworker) { instance_double(Coworkers::Coworker, id: 7) }
  let(:remote) { FakeBranchRemote.new }
  subject(:lifecycle) { described_class.new(coworker, remote: remote) }

  it "pushes the new ref, updates state, and then deletes the old ref" do
    state = []
    lifecycle.rename!(old_handle: "maya", new_handle: "nora") { state << :updated }

    expect(state).to eq([ :updated ])
    expect(remote.operations).to eq([
      [ :copy, "coworkers/maya", "coworkers/nora", 7 ],
      [ :delete, "coworkers/maya" ]
    ])
  end

  it "does not update state when pushing the new ref fails" do
    remote.fail_copy = true

    expect { lifecycle.rename!(old_handle: "maya", new_handle: "nora") { raise "state changed" } }
      .to raise_error("copy failed")
    expect(remote.operations).to eq([ [ :copy, "coworkers/maya", "coworkers/nora", 7 ] ])
  end

  it "removes the new ref and keeps the old ref when the database or registry update fails" do
    expect { lifecycle.rename!(old_handle: "maya", new_handle: "nora") { raise "update failed" } }
      .to raise_error("update failed")
    expect(remote.operations).to eq([
      [ :copy, "coworkers/maya", "coworkers/nora", 7 ],
      [ :delete, "coworkers/nora" ]
    ])
  end

  it "removes the new ref and reports failure when deleting the old ref fails" do
    remote.fail_delete = "coworkers/maya"

    expect { lifecycle.rename!(old_handle: "maya", new_handle: "nora") { :updated } }
      .to raise_error("delete failed")
    expect(remote.operations).to eq([
      [ :copy, "coworkers/maya", "coworkers/nora", 7 ],
      [ :delete, "coworkers/maya" ],
      [ :delete, "coworkers/nora" ]
    ])
  end

  it "moves a deleted coworker's home to a dated archive ref" do
    travel_to Time.zone.local(2026, 10, 29) do
      lifecycle.archive!(handle: "maya") { :destroyed }
    end

    expect(remote.operations).to eq([
      [ :copy, "coworkers/maya", "coworkers/archived/maya-2026-10-29", 7 ],
      [ :delete, "coworkers/maya" ]
    ])
  end
end
