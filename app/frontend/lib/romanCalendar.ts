const MONTHS_ABL = [
  "Ian.", "Feb.", "Mart.", "Apr.", "Mai.", "Iun.",
  "Iul.", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."
]

// March (3), May (5), July (7), October (10) have Nones on the 7th and Ides on the 15th
const LATE_NONES_MONTHS = new Set([3, 5, 7, 10])

function nonesDay(month: number): number {
  return LATE_NONES_MONTHS.has(month) ? 7 : 5
}

function idesDay(month: number): number {
  return LATE_NONES_MONTHS.has(month) ? 15 : 13
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

function toRomanNumeral(n: number): string {
  const values =   [1000, 900, 500, 400, 100, 90,  50, 40, 10, 9,   5,  4,  1]
  const numerals = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
  let result = ""
  for (let i = 0; i < values.length; i++) {
    while (n >= values[i]) {
      result += numerals[i]
      n -= values[i]
    }
  }
  return result
}

export function toRomanDate(isoString: string | null | undefined): string {
  if (!isoString) return ""
  const date = new Date(isoString)
  if (isNaN(date.getTime())) return ""

  const year = date.getUTCFullYear()
  const month = date.getUTCMonth() + 1
  const day = date.getUTCDate()

  const nones = nonesDay(month)
  const ides = idesDay(month)
  const monthAbl = MONTHS_ABL[month - 1]

  if (day === 1) return `Kal. ${monthAbl}`

  if (day < nones) {
    const count = nones - day + 1
    return count === 2 ? `prid. Non. ${monthAbl}` : `a.d. ${toRomanNumeral(count)} Non. ${monthAbl}`
  }

  if (day === nones) return `Non. ${monthAbl}`

  if (day < ides) {
    const count = ides - day + 1
    return count === 2 ? `prid. Id. ${monthAbl}` : `a.d. ${toRomanNumeral(count)} Id. ${monthAbl}`
  }

  if (day === ides) return `Id. ${monthAbl}`

  const nextMonth = month === 12 ? 1 : month + 1
  const nextMonthAbl = MONTHS_ABL[nextMonth - 1]
  const count = daysInMonth(year, month) - day + 2

  return count === 2 ? `prid. Kal. ${nextMonthAbl}` : `a.d. ${toRomanNumeral(count)} Kal. ${nextMonthAbl}`
}
