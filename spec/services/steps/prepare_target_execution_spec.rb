# frozen_string_literal: true

require "rails_helper"

RSpec.describe Steps::PrepareTargetExecution do
  # Regression: a failed prepare target raised NameError (a bare StepFailed
  # resolves lexically inside this module) and the grader's real failure was
  # lost behind "uninitialized constant Steps::PrepareTargetExecution::StepFailed".
  it "reports a failed prepare target command as a step failure" do
    host = Class.new do
      include Steps::PrepareTargetExecution

      def log(*) = nil
      def step = Struct.new(:kind).new("grader")
      def run = nil
      def workflow = nil
      def workspace = Struct.new(:path).new(Pathname.new(Dir.tmpdir))
      def env = {}
      def publish_command_completed!(**) = nil
      def prepare_dependency_status(_result) = "exit 1"
      def capture_git_status(**) = ""
    end.new
    failed = instance_double(ProcessRunner::Result, success?: false, timed_out: false, exit_status: 1)
    allow(ProcessRunner).to receive(:new).and_return(instance_double(ProcessRunner, run: failed))
    allow(ProcessRunner).to receive(:mounts).and_return([])

    expect {
      host.send(:execute_prepare_target_commands!, label: "//web:prepare", commands: [ "npm ci" ], workdir: Dir.tmpdir)
    }.to raise_error(Steps::Base::StepFailed, /prepare target \/\/web:prepare failed/)
  end
end
