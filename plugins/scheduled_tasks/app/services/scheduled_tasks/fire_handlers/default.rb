module ScheduledTasks
  module FireHandlers
    class Default < Base
      def applicable_behaviors = [ PR_PILEUP_POLICY, PR_BASED_AUTO_APPROVAL ].freeze

      def fire!(now:)
        task.skill_task? ? fire_skill_job! : fire_freeform_job!(now: now)
      end

      private

      def fire_freeform_job!(now:)
        prompt_renderer = ScheduledTasks::Prompt.new(scheduled_task: task, fired_at: now)
        rendered_prompt = prompt_renderer.to_s

        job = create_job!(issue_body: prompt_renderer.interpolated_user_prompt)
        workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
        WorkUnits::Launcher.start!(workflow, prompt: rendered_prompt)
        job
      end

      def fire_skill_job!
        args = task.skill_args.presence || {}
        job = create_job!(
          skill_name: task.skill_name,
          skill_args: args,
          issue_body: skill_issue_body_preview(args)
        )
        workflow = WorkUnits::Launcher.instantiate(kind: "skill", job: job, artifacts: job.skill_workflow_artifacts)
        WorkUnits::Launcher.start!(workflow, prompt: nil)
        job
      end

      def create_job!(**attributes)
        job = Job.create!(
          {
            user: task.user,
            repository: task.repository,
            kind: "cron",
            scheduled_task_id: task.id,
            origin: "scheduled_tasks",
            origin_id: task.id.to_s,
            issue_title: "Scheduled task: #{task.name}",
            issue_number: nil
          }.merge(attributes)
        )
        job.advance_after_triage! if job.may_advance_after_triage?
        job
      end

      def skill_issue_body_preview(args)
        resolution = Skills.for(repository: task.repository, name: task.skill_name, user: task.user)
        Skills::Renderer.render(resolution.definition, args)
      rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError
        "Skill: #{task.skill_name}"
      end
    end
  end
end
