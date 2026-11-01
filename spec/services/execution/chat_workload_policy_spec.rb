require "rails_helper"

RSpec.describe Execution::ChatWorkloadPolicy do
  # One switch, three modes, and the same answer for every chat agent. The
  # policy this replaced existed only for custom coworkers and was
  # unconditionally fail-closed, which made a disabled-by-default plugin a hard
  # dependency of every coworker chat turn.
  describe ".for_current_setting" do
    it "requests nothing when containment is off" do
      AppSetting.current.update!(contained_chat_execution: "off")

      expect(described_class.for_current_setting).to be_nil
    end

    it "requests containment that tolerates an unavailable backend when preferred" do
      AppSetting.current.update!(contained_chat_execution: "preferred")

      policy = described_class.for_current_setting

      expect(policy).to be_a(described_class)
      expect(policy).not_to be_fail_closed
      expect(policy).to be_chat_agent
      expect(policy.name).to eq("chat agent")
    end

    it "requests fail-closed containment when required" do
      AppSetting.current.update!(contained_chat_execution: "required")

      expect(described_class.for_current_setting).to be_fail_closed
    end
  end

  it "defaults to off, because containment depends on a plugin that ships disabled" do
    expect(AppSetting.new.contained_chat_execution).to eq("off")
    expect(AppSetting::CONTAINED_CHAT_EXECUTION_MODES).to eq(%w[ off preferred required ])
  end

  # Regression: a rolling deploy puts new code in front of a pre-migration
  # schema snapshot, because attribute methods come from the column list cached
  # at boot. Reading this unguarded raised
  # `NoMethodError: undefined method 'contained_chat_execution'` on the chat
  # turn path during a production rollout -- a hard failure where the honest
  # answer is simply "not configured".
  it "reads as off against a schema that predates its own column" do
    setting = AppSetting.current
    allow(AppSetting).to receive(:current).and_return(setting)
    allow(setting).to receive(:has_attribute?).with(:contained_chat_execution).and_return(false)

    expect { AppSetting.contained_chat_execution }.not_to raise_error
    expect(AppSetting.contained_chat_execution).to eq("off")
    expect(AppSetting.contained_chat_execution_requested?).to be(false)
    expect(described_class.for_current_setting).to be_nil
  end

  it "rejects a mode outside the tri-state" do
    setting = AppSetting.current
    setting.contained_chat_execution = "sometimes"

    expect(setting).not_to be_valid
    expect(setting.errors[:contained_chat_execution]).to be_present
  end
end
