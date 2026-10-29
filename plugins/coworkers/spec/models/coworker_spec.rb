require "rails_helper"

RSpec.describe Coworkers::Coworker do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }
  let(:branch_lifecycle) do
    instance_double(Coworkers::BranchLifecycle).tap do |lifecycle|
      allow(lifecycle).to receive(:rename!) { |**_, &block| block.call }
      allow(lifecycle).to receive(:archive!) { |**_, &block| block.call }
    end
  end

  before do
    allow(Coworkers::BranchLifecycle).to receive(:new).and_return(branch_lifecycle)
  end

  def create_coworker(attributes = {})
    described_class.create!({
      owner_user: owner,
      name: "Maya",
      handle: "maya",
      workspace_repo: "git@example.com:workspaces.git"
    }.merge(attributes))
  end

  it "claims, renames, and releases its shared handle" do
    coworker = create_coworker
    expect(coworker.handle_record.reload.handle).to eq("maya")

    coworker.update!(handle: "maya-renamed")
    expect(coworker.handle_record.reload.handle).to eq("maya-renamed")
    expect(branch_lifecycle).to have_received(:rename!).with(old_handle: "maya", new_handle: "maya-renamed")

    coworker.destroy!
    expect(Handle.exists?(owner: coworker)).to be(false)
    expect(branch_lifecycle).to have_received(:archive!).with(handle: "maya-renamed")
  end

  it "refuses a rename while a chat turn is in flight" do
    coworker = create_coworker
    chat = ChatSession.create!(user: owner, title: "Busy", turn_in_flight: true)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    expect { coworker.update!(handle: "blocked") }.to raise_error(Coworkers::OperationLock::Busy)
    expect(coworker.reload.handle).to eq("maya")
    expect(coworker.handle_record.reload.handle).to eq("maya")
    expect(branch_lifecycle).not_to have_received(:rename!)
  end

  it "keeps the old handle when the handle registry update fails" do
    coworker = create_coworker
    allow(HandleRegistry).to receive(:rename!).and_raise("registry failed")

    expect { coworker.update!(handle: "nora") }.to raise_error("registry failed")
    expect(coworker.reload.handle).to eq("maya")
    expect(coworker.handle_record.reload.handle).to eq("maya")
  end

  it "rolls the database and handle registry back when the branch move cannot finish" do
    coworker = create_coworker
    allow(branch_lifecycle).to receive(:rename!) do |**_, &block|
      block.call
      raise "old ref could not be deleted"
    end

    expect { coworker.update!(handle: "nora") }.to raise_error("old ref could not be deleted")
    expect(coworker.reload.handle).to eq("maya")
    expect(coworker.handle_record.reload.handle).to eq("maya")
  end

  it "archives on delete and permits the freed handle to be reused" do
    coworker = create_coworker
    coworker.destroy!

    replacement = create_coworker
    expect(replacement.handle).to eq("maya")
    expect(branch_lifecycle).to have_received(:archive!).with(handle: "maya")
  end

  it "cannot claim a reserved or already claimed handle" do
    Handle.find_or_create_by!(handle: "syrus")
    expect { create_coworker(handle: "syrus") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "defaults its color deterministically from the normalized handle" do
    coworker = create_coworker(handle: "MAYA")
    expect(coworker.color_key).to eq(Appearance::ColorPalette.default_key("maya"))
  end

  it "enforces unique capabilities per coworker" do
    coworker = create_coworker
    coworker.grants.create!(capability: "workspace.files", approval_policy: "auto")
    duplicate = coworker.grants.new(capability: "workspace.files", approval_policy: "confirm")

    expect(duplicate).not_to be_valid
  end

  it "accepts only a size-capped image as its single uploaded avatar" do
    coworker = create_coworker
    coworker.avatar.attach(io: StringIO.new("not an image"), filename: "avatar.txt", content_type: "text/plain")

    expect(coworker).not_to be_valid
    expect(coworker.errors[:avatar]).to include("must be an image")
  end
end
