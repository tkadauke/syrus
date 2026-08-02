require "rails_helper"

RSpec.describe AgentRole do
  describe "constants" do
    it "defines all chat roles" do
      expect(described_class::CHAT_PLANNER).to    eq("chat:planner")
      expect(described_class::CHAT_ADMIN).to      eq("chat:admin")
      expect(described_class::CHAT_CODING).to     eq("chat:coding")
      expect(described_class::CHAT_LOCAL).to      eq("chat:local")
      expect(described_class::CHAT_WALKTHROUGH).to eq("chat:walkthrough")
      expect(described_class::CHAT_EVALUATOR).to  eq("chat:evaluator")
    end

    it "defines all workflow roles" do
      expect(described_class::WORKFLOW_IMPLEMENT).to                eq("workflow:implement")
      expect(described_class::WORKFLOW_REBASE_CONFLICT).to          eq("workflow:rebase_conflict")
      expect(described_class::WORKFLOW_SUMMARY_TEST_PLAN).to        eq("workflow:summary_test_plan")
      expect(described_class::WORKFLOW_ADVERSARIAL_REVIEWER).to     eq("workflow:adversarial_reviewer")
      expect(described_class::WORKFLOW_MANUAL).to                   eq("workflow:manual")
      expect(described_class::WORKFLOW_RECONCILIATION_FEEDBACK).to  eq("workflow:reconciliation_feedback")
    end

    it "defines all helper roles" do
      expect(described_class::HELPER_INGESTION).to    eq("helper:ingestion")
      expect(described_class::HELPER_PR_COMMENT).to   eq("helper:pr_comment")
      expect(described_class::HELPER_CHAT_TITLE).to   eq("helper:chat_title")
      expect(described_class::HELPER_DIRECT_TITLE).to eq("helper:direct_title")
      expect(described_class::HELPER_PR_COPY).to      eq("helper:pr_copy")
      expect(described_class::HELPER_WALKTHROUGH).to  eq("helper:walkthrough")
    end

    it "defines infrastructure and insight roles" do
      expect(described_class::INFRASTRUCTURE_MAIN_REPAIR).to eq("infrastructure:main_repair")
      expect(described_class::AGENT_INSIGHT).to               eq("agent:insight")
    end

    it "collects workflow roles into WORKFLOW_ROLES" do
      expect(described_class::WORKFLOW_ROLES).to contain_exactly(
        described_class::WORKFLOW_IMPLEMENT,
        described_class::WORKFLOW_REBASE_CONFLICT,
        described_class::WORKFLOW_SUMMARY_TEST_PLAN,
        described_class::WORKFLOW_ADVERSARIAL_REVIEWER,
        described_class::WORKFLOW_MANUAL,
        described_class::WORKFLOW_RECONCILIATION_FEEDBACK
      )
    end

    it "collects chat roles into CHAT_ROLES" do
      expect(described_class::CHAT_ROLES).to contain_exactly(
        described_class::CHAT_PLANNER,
        described_class::CHAT_ADMIN,
        described_class::CHAT_CODING,
        described_class::CHAT_LOCAL,
        described_class::CHAT_WALKTHROUGH,
        described_class::CHAT_EVALUATOR
      )
    end

    it "collects helper roles into HELPER_ROLES" do
      expect(described_class::HELPER_ROLES).to contain_exactly(
        described_class::HELPER_INGESTION,
        described_class::HELPER_PR_COMMENT,
        described_class::HELPER_CHAT_TITLE,
        described_class::HELPER_DIRECT_TITLE,
        described_class::HELPER_PR_COPY,
        described_class::HELPER_WALKTHROUGH
      )
    end

    it "has no duplicate values across ALL_ROLES" do
      expect(described_class::ALL_ROLES.uniq).to eq(described_class::ALL_ROLES)
    end
  end
end
