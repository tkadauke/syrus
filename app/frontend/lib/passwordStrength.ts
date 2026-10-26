// Entropy-based password strength for the setup/signup forms. Estimate:
// bits = length x log2(charset size), with the charset inferred from which
// character classes appear. Deliberately simple — this is guidance UI, not
// a gate; the classic caveat (dictionary words look stronger than they are)
// is acceptable for an indicator.

export type PasswordStrength = {
  bits: number
  // 0 = empty, 1 = weak, 2 = fair, 3 = good, 4 = strong
  score: 0 | 1 | 2 | 3 | 4
}

export function passwordStrength(password: string): PasswordStrength {
  if (password.length === 0) {
    return { bits: 0, score: 0 }
  }

  let charset = 0
  if (/[a-z]/.test(password)) charset += 26
  if (/[A-Z]/.test(password)) charset += 26
  if (/[0-9]/.test(password)) charset += 10
  if (/[^a-zA-Z0-9]/.test(password)) charset += 33

  // Repeated single characters ("aaaaaaaa") carry almost no entropy;
  // count distinct characters against a floor so they read as weak.
  const distinct = new Set(password).size
  const effectiveLength = Math.min(password.length, distinct * 2)
  const bits = Math.round(effectiveLength * Math.log2(Math.max(charset, 2)))

  if (bits < 35) return { bits, score: 1 }
  if (bits < 55) return { bits, score: 2 }
  if (bits < 75) return { bits, score: 3 }
  return { bits, score: 4 }
}
