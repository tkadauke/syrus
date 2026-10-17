require "rails_helper"

RSpec.describe JavaScript::FocusedTestCommand do
  it "derives an exact-test isolated repro command" do
    command = described_class.isolated_command_for(
      grader_name: "vitest",
      grader_command: "npx vitest run",
      test_case: { "file_path" => "src/foo.test.ts", "name" => "does the thing" }
    )

    expect(command).to include("src/foo.test.ts -t does\\ the\\ thing")
  end

  it "focuses JavaScript graders to failed test files" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "npx vitest run",
      failed_cases: [
        { "file_path" => "app/frontend/routes/App.test.tsx", "name" => "renders dashboard" },
        { "suite_name" => "plugins/demo/app/frontend/demo.spec.ts", "name" => "renders" }
      ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to include("npm ci")
    expect(command).to include("npx vitest run --maxWorkers=1")
    expect(command).to include("--reporter=junit")
    expect(command).to include("app/frontend/routes/App.test.tsx plugins/demo/app/frontend/demo.spec.ts")
  end

  it "uses lockfile-specific package managers and freshness markers" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "npx vitest run",
      failed_cases: [ { "file_path" => "app.test.tsx" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to include("[ -f yarn.lock ]", "node_modules/.yarn-integrity", "yarn install --frozen-lockfile")
    expect(command).to include("[ -f pnpm-lock.yaml ]", "node_modules/.modules.yaml", "pnpm install --frozen-lockfile")
    expect(command).to include("[ -f package-lock.json ]", "node_modules/.package-lock.json", "npm ci")
    expect(command).to include("elif [ -f package.json ]; then", "npm install")
  end

  it "runs in the grader project directory with project-relative test paths" do
    command = described_class.command_for(
      grader_name: "website-tests",
      grader_command: "npx vitest run",
      failed_cases: [ { "file_path" => "website/src/app.test.tsx" } ],
      base_retry: { "strategy" => "plugin" },
      project_path: "website"
    )

    expect(command).to start_with("cd website &&")
    expect(command).to include("--outputFile.junit=../.syrus/grade-output/website-tests-junit.xml")
    expect(command).to end_with("src/app.test.tsx")
    expect(command).not_to include("website/src/app.test.tsx")
  end

  it "declines when the grader did not opt into plugin strategy" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "npx vitest run",
      failed_cases: [ { "file_path" => "app/frontend/routes/App.test.tsx", "name" => "renders dashboard" } ],
      base_retry: { "strategy" => "files_as_args" }
    )

    expect(command).to be_nil
  end

  it "declines non-JavaScript graders" do
    command = described_class.command_for(
      grader_name: "rspec",
      grader_command: "bundle exec rspec",
      failed_cases: [ { "file_path" => "spec/models/job_spec.rb", "name" => "works" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to be_nil
  end
end
