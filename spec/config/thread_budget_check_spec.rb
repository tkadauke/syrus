# frozen_string_literal: true

require "open3"

RSpec.describe "thread budget check" do
  it "evaluates queue and database config ERB outside Rails" do
    stdout, stderr, status = Open3.capture3("ruby", "bin/check-thread-budget")

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-thread-budget] ok")
  end
end
