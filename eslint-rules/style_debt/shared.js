"use strict"

// Shared plumbing for the DOC-27 style-debt *reporting* rules under this
// directory. Unlike the enforced ratchet rules in eslint-rules/ (which fail
// lint beyond a per-file baseline), these rules always report every match --
// bin/style-debt-report aggregates their output into counts instead of
// gating CI. See config/syrus_docs/style_debt_report.md.
//
// The exclusion set itself (design-system files, generated files, documented
// exceptions) is shared verbatim with the enforced ratchet rules -- it lives
// in ../rule-utils.js so both sides of the ratchet stay in sync.

const {
  relativePath,
  collectStringLiterals,
  classNameCandidates,
  DESIGN_SYSTEM_DIR_PREFIX,
  DESIGN_SYSTEM_BASENAMES,
  DOCUMENTED_EXCEPTIONS,
  isDesignSystemExcluded
} = require("../rule-utils")

module.exports = {
  DESIGN_SYSTEM_DIR_PREFIX,
  DESIGN_SYSTEM_BASENAMES,
  DOCUMENTED_EXCEPTIONS,
  isExcluded: isDesignSystemExcluded,
  relativePath,
  collectStringLiterals,
  classNameCandidates
}
