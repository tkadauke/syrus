# frozen_string_literal: true

require_relative "deploy_helper"
require "tmpdir"
require "stringio"

RSpec.describe Deploy::Shell do
  let(:out) { StringIO.new }
  let(:stream) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: StringIO.new) }

  def shell(dry_run:, stream: nil)
    described_class.new(reporter: reporter, clock: Deploy::Clock::Immediate.new,
      dry_run: dry_run, stream: stream)
  end

  describe "a dry run" do
    subject(:dry) { shell(dry_run: true, stream: stream) }

    it "records a mutation instead of running it" do
      result = dry.write(%w[kubectl -n syrus apply -f -])

      expect(result).to be_success
      expect(stream.string).to eq("DRYRUN kubectl -n syrus apply -f -\n")
    end

    # The deploy derives nearly everything it does from live cluster state, so
    # a dry run that could not read would describe a deploy against a cluster
    # it never looked at -- which is worse than no answer, because it looks
    # like one.
    it "still performs reads" do
      result = dry.read([ "/bin/echo", "live-state" ])

      expect(result.out).to include("live-state")
      expect(stream.string).to be_empty
    end

    it "reports a mutation as having succeeded so later phases behave normally" do
      expect(dry.write(%w[kubectl -n syrus delete job/x])).to be_success
    end
  end

  describe "the read/write declaration" do
    # Intent and argv have to agree. The bash implementation could only guess
    # from argv, because shadowing `kubectl` as a function gave it no caller
    # context; declaring intent lets the guess become an assertion instead.
    it "refuses to issue a mutating verb as a read" do
      expect { shell(dry_run: true).read(%w[kubectl -n syrus delete job/x]) }
        .to raise_error(Deploy::Failure, /kubectl delete was issued as a read/)
    end

    # Global flags take values, so the verb is not the first bare argument.
    it "finds the verb past leading flags and their values" do
      expect { shell(dry_run: true).read(%w[kubectl -n syrus --context prod patch cronjob x]) }
        .to raise_error(Deploy::Failure, /kubectl patch/)
    end

    # The consequential default: a subcommand nobody has classified must not be
    # assumed safe.
    it "treats an unrecognised verb as a mutation" do
      expect { shell(dry_run: true).read(%w[kubectl -n syrus some-future-verb thing]) }
        .to raise_error(Deploy::Failure, /was issued as a read/)
    end

    it "lets every read verb through" do
      described_class::KUBECTL_READ_VERBS.each do |verb|
        expect { shell(dry_run: true).read([ "/bin/echo", "kubectl", "-n", "x", verb ]) }.not_to raise_error
      end
    end
  end

  describe "a real run" do
    it "runs both reads and writes" do
      real = shell(dry_run: false)

      expect(real.read([ "/bin/echo", "read" ]).out).to include("read")
      expect(real.write([ "/bin/echo", "write" ]).out).to include("write")
      expect(real.recorded).to be_empty
    end

    it "reports a non-zero exit rather than raising" do
      expect(shell(dry_run: false).read([ "/bin/sh", "-c", "exit 3" ]).status).to eq(3)
    end

    it "fails with an operator-readable message when the binary is missing" do
      expect { shell(dry_run: false).read([ "definitely-not-a-binary" ]) }
        .to raise_error(Deploy::Failure, /definitely-not-a-binary/)
    end
  end

  describe "the recorded stream" do
    it "captures to a file for diffing against another implementation" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "stream.txt")
        File.open(path, "w") do |file|
          shell(dry_run: true, stream: file).write(%w[kubectl -n syrus apply -f -])
        end

        expect(File.read(path)).to eq("DRYRUN kubectl -n syrus apply -f -\n")
      end
    end

    # In the bash implementation the stream went to stdout, and the Flux and
    # cronjob patches end in `>/dev/null` -- which dropped precisely the writes
    # the stream exists to record. Holding the sink in-process makes that
    # unreachable, and this asserts the property rather than the mechanism.
    it "cannot be silenced by a caller that discards output" do
      file = StringIO.new
      dry = shell(dry_run: true, stream: file)

      silenced = $stdout
      begin
        $stdout = StringIO.new
        dry.write(%w[kubectl -n flux-system patch kustomization apps])
      ensure
        $stdout = silenced
      end

      expect(file.string).to include("patch kustomization apps")
    end
  end
end
