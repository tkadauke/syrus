require "rails_helper"

RSpec.describe Prompts::ShellCommandExecutionContract do
  it "keeps agent verification focused and leaves broad checks to graders" do
    text = described_class::TEXT

    expect(text).to include("Run focused local validation only")
    expect(text).to include("Do not run broad/full-suite validation")
    expect(text).to include("configured graders")
    expect(text).to include("parallel after your step")
  end
end
