require "rails_helper"

RSpec.describe DirectJobTitleGenerator do
  it "uses the first meaningful sentence from the prompt" do
    title = described_class.call("\n\nUpdate the Ruby version. Then run the checks.")

    expect(title).to eq("Update the Ruby version.")
  end

  it "cleans markdown and wrapping punctuation from noisy prompt text" do
    title = described_class.call("### `Fix the login form`\n\n- Add regression specs")

    expect(title).to eq("Fix the login form")
  end

  it "truncates long multibyte prompts without invalid UTF-8" do
    title = described_class.call("#{"修" * 60} finish the dashboard")

    expect(title.bytesize).to be <= described_class::MAX_TITLE_BYTES
    expect(title).to be_valid_encoding
  end

  it "falls back when the prompt has no useful title text" do
    expect(described_class.call("```\n")).to eq("Direct job")
  end
end
