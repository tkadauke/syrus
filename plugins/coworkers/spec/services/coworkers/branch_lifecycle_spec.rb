require "rails_helper"

RSpec.describe Coworkers::BranchLifecycle do
  class BranchLifecycleRemoteFake
    attr_reader :branches
    attr_accessor :fail_on

    def initialize(branches)
      @branches = branches.to_set
    end

    def branch_exists?(branch) = branches.include?(branch)

    def copy!(source:, destination:, guard:)
      guard.allow!(source)
      guard.allow!(destination)
      raise "copy failed" if fail_on == :copy
      raise ArgumentError, "destination branch already exists" if branch_exists?(destination)
      branches.add(destination)
    end

    def guarded_delete!(branch, guard:)
      guard.allow!(branch)
      raise "delete failed" if fail_on == :delete
      branches.delete(branch)
      if fail_on == :after_delete
        self.fail_on = nil
        raise "transaction commit failed"
      end
    end
  end

  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/homes.git")
  end
  let(:remote) { BranchLifecycleRemoteFake.new([ "coworkers/maya" ]) }
  subject(:lifecycle) { described_class.new(coworker, remote:, date: Date.new(2026, 10, 29)) }

  it "moves the home branch and handle together" do
    lifecycle.rename!(handle: "maya-renamed")

    expect(remote.branches).to contain_exactly("coworkers/maya-renamed")
    expect(coworker.reload.handle).to eq("maya-renamed")
    expect(Handle.find_by!(owner: coworker).handle).to eq("maya-renamed")
  end

  it "keeps the old branch and handle when copying fails" do
    remote.fail_on = :copy
    expect { lifecycle.rename!(handle: "maya-renamed") }.to raise_error("copy failed")
    expect(remote.branches).to contain_exactly("coworkers/maya")
    expect(coworker.reload.handle).to eq("maya")
  end

  it "rolls the database and new ref back when deleting the old ref fails" do
    remote.fail_on = :delete
    expect { lifecycle.rename!(handle: "maya-renamed") }.to raise_error("delete failed")
    remote.fail_on = nil
    expect(coworker.reload.handle).to eq("maya")
    expect(Handle.find_by!(owner: coworker).handle).to eq("maya")
  end

  it "removes the new ref and keeps the old identity when the database step fails" do
    allow(HandleRegistry).to receive(:rename!).and_raise(ActiveRecord::RecordInvalid.new(Handle.new))

    expect { lifecycle.rename!(handle: "maya-renamed") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(remote.branches).to contain_exactly("coworkers/maya")
    expect(coworker.reload.handle).to eq("maya")
    expect(Handle.find_by!(owner: coworker).handle).to eq("maya")
  end

  it "restores the old ref when the transaction fails after deleting it" do
    remote.fail_on = :after_delete

    expect { lifecycle.rename!(handle: "maya-renamed") }.to raise_error("transaction commit failed")
    expect(remote.branches).to contain_exactly("coworkers/maya")
    expect(coworker.reload.handle).to eq("maya")
    expect(Handle.find_by!(owner: coworker).handle).to eq("maya")
  end

  it "refuses a rename while a turn is in flight" do
    chat = ChatSession.create!(user: owner, title: "Maya", turn_in_flight: true)
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")

    expect { lifecycle.rename!(handle: "maya-renamed") }.to raise_error(Coworkers::OperationLock::Busy)
    expect(remote.branches).to contain_exactly("coworkers/maya")
  end

  it "archives on delete, frees the handle, and avoids a same-day reuse collision" do
    expect(lifecycle.archive!).to eq("coworkers/archived/maya-2026-10-29")
    replacement = Coworkers::Coworker.create!(owner_user: owner, name: "Maya II", handle: "maya", workspace_repo: coworker.workspace_repo)
    remote.branches.add("coworkers/maya")

    second = described_class.new(replacement, remote:, date: Date.new(2026, 10, 29)).archive!

    expect(second).to eq("coworkers/archived/maya-2026-10-29-2")
    expect(Handle.where(handle: "maya")).to be_empty
  end


  it "restores the home ref and coworker when archive commit fails after deletion" do
    remote.fail_on = :after_delete

    expect { lifecycle.archive! }.to raise_error("transaction commit failed")
    expect(remote.branches).to contain_exactly("coworkers/maya")
    expect(Coworkers::Coworker.find(coworker.id).handle).to eq("maya")
    expect(Handle.find_by!(owner: coworker).handle).to eq("maya")
  end
end
