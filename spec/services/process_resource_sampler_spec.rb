require "rails_helper"

RSpec.describe ProcessResourceSampler do
  def write_process(proc_root, pid:, pgid:, cpu_ticks:, child_cpu_ticks: 0, read_bytes:, write_bytes:)
    process_dir = File.join(proc_root, pid.to_s)
    FileUtils.mkdir_p(process_dir)
    fields = Array.new(22, "0")
    fields[0] = "S"
    fields[2] = pgid.to_s
    fields[11] = cpu_ticks.to_s
    fields[13] = child_cpu_ticks.to_s
    fields[21] = "1"
    File.write(File.join(process_dir, "stat"), "#{pid} (test process) #{fields.join(' ')}\n")
    File.write(File.join(process_dir, "io"), "read_bytes: #{read_bytes}\nwrite_bytes: #{write_bytes}\n")
  end

  it "retains counters for processes that exit between samples" do
    Dir.mktmpdir do |proc_root|
      sampler = described_class.new(pid: 10, pgid: 10, proc_root: proc_root)
      allow(sampler).to receive(:clock_ticks).and_return(100)
      allow(sampler).to receive(:page_size).and_return(4096)
      write_process(proc_root, pid: 10, pgid: 10, cpu_ticks: 100, read_bytes: 100, write_bytes: 200)
      sampler.sample!

      write_process(proc_root, pid: 11, pgid: 10, cpu_ticks: 50, read_bytes: 300, write_bytes: 400)
      sampler.sample!
      FileUtils.rm_r(File.join(proc_root, "11"))
      write_process(proc_root, pid: 10, pgid: 10, cpu_ticks: 120, child_cpu_ticks: 50, read_bytes: 120, write_bytes: 220)
      sampler.sample!

      expect(sampler.payload).to include(
        "confidence" => "low",
        "cpu_time_seconds" => 0.7,
        "read_io_bytes" => be >= 300,
        "write_io_bytes" => be >= 400
      )
    end
  end

  it "never reports negative cumulative deltas" do
    Dir.mktmpdir do |proc_root|
      sampler = described_class.new(pid: 10, pgid: 10, proc_root: proc_root)
      allow(sampler).to receive(:clock_ticks).and_return(100)
      allow(sampler).to receive(:page_size).and_return(4096)
      write_process(proc_root, pid: 10, pgid: 10, cpu_ticks: 100, read_bytes: 100, write_bytes: 100)
      write_process(proc_root, pid: 11, pgid: 10, cpu_ticks: 100, read_bytes: 100, write_bytes: 100)
      sampler.sample!
      FileUtils.rm_r(File.join(proc_root, "11"))
      sampler.sample!

      expect(sampler.payload.values_at("cpu_time_seconds", "read_io_bytes", "write_io_bytes")).to all(be >= 0)
    end
  end

  it "includes CPU from children that start and are reaped between samples" do
    Dir.mktmpdir do |proc_root|
      sampler = described_class.new(pid: 10, pgid: 10, proc_root: proc_root)
      allow(sampler).to receive(:clock_ticks).and_return(100)
      allow(sampler).to receive(:page_size).and_return(4096)
      write_process(proc_root, pid: 10, pgid: 10, cpu_ticks: 100, read_bytes: 100, write_bytes: 100)
      sampler.sample!
      write_process(
        proc_root,
        pid: 10,
        pgid: 10,
        cpu_ticks: 120,
        child_cpu_ticks: 30,
        read_bytes: 100,
        write_bytes: 100
      )
      sampler.sample!

      expect(sampler.payload["cpu_time_seconds"]).to eq(0.5)
    end
  end

  it "lowers confidence when the entire process group has exited" do
    Dir.mktmpdir do |proc_root|
      sampler = described_class.new(pid: 10, pgid: 10, proc_root: proc_root)
      allow(sampler).to receive(:clock_ticks).and_return(100)
      allow(sampler).to receive(:page_size).and_return(4096)
      write_process(proc_root, pid: 10, pgid: 10, cpu_ticks: 100, read_bytes: 100, write_bytes: 100)
      sampler.sample!
      sampler.sample!
      FileUtils.rm_r(File.join(proc_root, "10"))
      sampler.sample!

      expect(sampler.payload["confidence"]).to eq("low")
    end
  end
end
