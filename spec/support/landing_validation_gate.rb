# Landing steps (Steps::AutoMerge, Steps::MergeTrainLand) refuse to merge a SHA
# without a SHA-bound LandingValidationManifest. Specs that exercise the rest of
# those steps shouldn't each have to grade a tree first, so the gate defaults to
# a passing verdict. Specs that test the gate itself opt out with
# `:real_landing_validation_gate` and drive LandingValidationManifest directly.
RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:real_landing_validation_gate]

    allow(LandingValidationManifest).to receive(:gate) do |sha:, **|
      LandingValidationManifest::Verdict.new(true, "exact_head", { "head_sha" => sha, "targets" => [] }, [])
    end
  end
end
