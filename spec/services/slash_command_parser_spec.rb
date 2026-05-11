require "rails_helper"

RSpec.describe SlashCommandParser do
  it "recognizes approve-family commands at the start of a line" do
    result = described_class.parse("looks good\n  /Approve after thought")
    expect(result).to be_approve
    expect(result.command).to eq("/approve")
  end

  it "takes the last command in a comment" do
    result = described_class.parse("/approve\nchanged my mind\n/unapprove")
    expect(result).to be_unapprove
  end

  it "ignores commands inside fenced and inline code" do
    result = described_class.parse("`/approve`\n```\n/unapprove\n```\n/lgtm")
    expect(result).to be_approve
    expect(result.command).to eq("/lgtm")
  end

  it "recognizes reject-family commands without treating them as approval" do
    result = described_class.parse("/rejected")
    expect(result).to be_reject
    expect(result).not_to be_approve
  end

  it "ignores commands that do not start a line" do
    expect(described_class.parse("please /approve this")).to be_nil
  end
end
