# frozen_string_literal: true

require "open3"
require "rails_helper"

RSpec.describe "JavaScript controller specs" do
  test_files = Dir[Rails.root.join("spec/javascript/*.test.mjs")].sort

  before(:context) do
    @javascript_stdout, @javascript_stderr, @javascript_status =
      Open3.capture3("node", "--test", *test_files)
    @javascript_failure_output = [ @javascript_stdout, @javascript_stderr ].reject(&:blank?).join("\n")
  end

  test_files.each do |test_file|
    it "passes #{Pathname.new(test_file).basename}" do
      expect(@javascript_status).to be_success, @javascript_failure_output
    end
  end
end
