require "rails_helper"

RSpec.describe EpicDependency do
  let(:user) { Factories.user }

  it "rejects self references" do
    epic = Factories.epic(user: user)

    dependency = described_class.new(epic: epic, depends_on_epic: epic)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_epic]).to include("can't be the same Epic")
  end

  it "rejects cycles" do
    root = Factories.epic(user: user)
    middle = Factories.epic(user: user)
    leaf = Factories.epic(user: user)
    described_class.create!(epic: leaf, depends_on_epic: middle)
    described_class.create!(epic: middle, depends_on_epic: root)

    dependency = described_class.new(epic: root, depends_on_epic: leaf)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_epic]).to include("would create a cycle")
  end
end
