require "rails_helper"
require "ostruct"

# Steps::Grader hands a grader's runtime-profile destinations to the grader
# input materializers from its Step details; fan-out builds those details from
# an allowlist of plugin metadata, so a key left off it is silently dropped.
RSpec.describe Steps::GraderFanout, "runtime profile details" do
  it "carries the runtime profile destinations into the grader Step details" do
    grader = OpenStruct.new(
      name: "rspec-ci-2-of-4", display_name: "RSpec (CI) 2/4", command: "bin/rspec", resources: nil,
      description: nil, required: true, timeout_minutes: 150, when_files_changed: [], junit_output: nil,
      failures: "strict", base_retry: nil,
      metadata: {
        "grader_framework" => "rspec",
        "runtime_profile_destination" => ".syrus/parallel_runtime_rspec-ci-2-of-4.log",
        "shard_runtime_profile_destination" => ".syrus/shard_runtime_rspec-ci.log",
        "shard_runtime_profile_key" => "rspec-ci"
      }
    )
    handler = described_class.allocate
    allow(handler).to receive_messages(target_label_for: "//:grade/rspec-ci-2-of-4", ci_checks_for: [], target_capabilities_for: {})

    details = handler.send(:grader_details, grader, prepare_targets: [], target_fingerprints: OpenStruct.new(to_h: {}))

    expect(details).to include(
      "runtime_profile_destination" => ".syrus/parallel_runtime_rspec-ci-2-of-4.log",
      "shard_runtime_profile_destination" => ".syrus/shard_runtime_rspec-ci.log",
      "shard_runtime_profile_key" => "rspec-ci"
    )
  end
end
