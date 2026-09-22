require "rails_helper"

RSpec.describe "bin/deploy clean-tree preflight" do
  subject(:deploy) { Rails.root.join("bin/deploy").read }

  it "refreshes Git metadata and includes untracked files" do
    expect(deploy).to include("git status --porcelain=v1 --untracked-files=normal")
    expect(deploy).not_to include("git diff-index --quiet HEAD")
  end
end
