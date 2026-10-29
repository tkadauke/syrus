require "rails_helper"

RSpec.describe Coworkers::Coworker do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }

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

    coworker.destroy!
    expect(Handle.exists?(owner: coworker)).to be(false)
  end

  it "cannot claim a reserved or already claimed handle" do
    Handle.find_or_create_by!(handle: "syrus")
    expect { create_coworker(handle: "syrus") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "defaults to the first unused accent color for the owner" do
    create_coworker(handle: "ada", accent_hex: "#0090FF")
    coworker = create_coworker(handle: "MAYA")
    expect(coworker.accent_hex).to eq("#F5A524")
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
