require "rails_helper"

RSpec.describe RunJob, "MySQL lifecycle lock waits", :ci_only do
  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name == "Mysql2"
  end

  after do
    Job.where(issue_title: "RunJob lock-wait reproduction").find_each(&:destroy!)
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  %w[runs merges].each do |queue|
    it "retries execution acquisition on the #{queue} queue without invoking a handler" do
      job = Factories.job_record(issue_title: "RunJob lock-wait reproduction")
      run = job.initial_run
      ready_reader, ready_writer = IO.pipe
      holder = fork do
        ready_reader.close
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.connection_pool.with_connection do
          Run.transaction do
            Run.lock.find(run.id)
            ready_writer.write("1")
            ready_writer.close
            sleep 1.2
          end
        end
        exit! 0
      end
      ready_writer.close
      expect(ready_reader.read(1)).to eq("1")
      ready_reader.close

      ActiveRecord::Base.connection_handler.clear_all_connections!
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        previous_timeout = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout").to_i
        connection.execute("SET SESSION innodb_lock_wait_timeout = 1")
        executor = described_class.new
        executor.queue_name = queue
        executor.instance_variable_set(:@run, Run.find(run.id))
        executor.instance_variable_set(:@step, run.step)
        executor.instance_variable_set(:@workflow, run.workflow)
        executor.instance_variable_set(:@job, job)

        expect(executor.send(:acquire_run_execution!)).to be(true)
      ensure
        connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous_timeout}") if previous_timeout
      end

      Process.wait(holder)
      holder = nil
      expect(run.reload).to be_running
    ensure
      if holder
        unless Process.waitpid(holder, Process::WNOHANG)
          Process.kill("TERM", holder)
          Process.wait(holder)
        end
      end
    end
  end
end
