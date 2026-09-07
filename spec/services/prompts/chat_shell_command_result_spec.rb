require "rails_helper"

RSpec.describe Prompts::ChatShellCommandResult do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def build_command(**attributes)
    ChatShellCommand.new({ chat_session: chat_session, user: user, started_at: Time.current, command: "git status" }.merge(attributes))
  end

  it "includes the exact command that ran" do
    prompt = described_class.new(chat_shell_command: build_command(command: "bin/rspec spec/models")).to_s

    expect(prompt).to include("$ bin/rspec spec/models")
  end

  it "includes the captured output" do
    prompt = described_class.new(chat_shell_command: build_command(output: "nothing to commit, working tree clean")).to_s

    expect(prompt).to include("nothing to commit, working tree clean")
  end

  it "renders a placeholder when there is no output" do
    prompt = described_class.new(chat_shell_command: build_command(output: nil)).to_s

    expect(prompt).to include("(no output)")
  end

  it "reports a successful outcome with exit status" do
    prompt = described_class.new(chat_shell_command: build_command(outcome: "succeeded", exit_status: 0)).to_s

    expect(prompt).to include("succeeded, exit 0")
  end

  it "reports a failed outcome with exit status" do
    prompt = described_class.new(chat_shell_command: build_command(outcome: "failed", exit_status: 1)).to_s

    expect(prompt).to include("failed, exit 1")
  end

  it "explains a cancelled command without an exit status" do
    prompt = described_class.new(chat_shell_command: build_command(outcome: "killed", exit_status: nil)).to_s

    expect(prompt).to include("cancelled by the operator before it finished")
    expect(prompt).not_to include("exit")
  end

  it "explains a command that could not run at all" do
    prompt = described_class.new(chat_shell_command: build_command(outcome: "error", exit_status: nil)).to_s

    expect(prompt).to include("could not run")
  end
end
