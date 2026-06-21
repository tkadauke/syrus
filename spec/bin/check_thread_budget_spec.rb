require "rails_helper"
require "open3"

RSpec.describe "bin/check-thread-budget" do
  let(:script) { Rails.root.join("bin/check-thread-budget").to_s }

  def run_script(env_overrides = {})
    env = {
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH")
    }.merge(env_overrides)

    Open3.capture3(env, "ruby", script, unsetenv_others: true)
  end

  it "renders Rails-style config ERB before checking queue thread budget" do
    stdout, stderr, status = run_script

    expect(status).to be_success, "expected success, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).to be_empty
  end

  it "renders the production SQLite branch without Rails present? helpers loaded" do
    stdout, stderr, status = run_script("SYRUS_SQLITE" => "1")

    expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
  end
end
