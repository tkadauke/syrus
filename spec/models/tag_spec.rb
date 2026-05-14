require "rails_helper"

RSpec.describe Tag, type: :model do
  it "allows the same tag name for different users but not the same user" do
    user = Factories.user
    other = Factories.user

    Factories.tag(user: user, name: "urgent")

    expect(Factories.tag(user: other, name: "urgent")).to be_persisted
    expect(Tag.new(user: user, name: "urgent", color: "gray")).not_to be_valid
  end

  it "accepts palette keys and hex colors" do
    expect(Tag.new(user: Factories.user, name: "area:auth", color: "blue")).to be_valid
    expect(Tag.new(user: Factories.user, name: "area:billing", color: "#123abc")).to be_valid
    expect(Tag.new(user: Factories.user, name: "bad", color: "loud")).not_to be_valid
  end
end
