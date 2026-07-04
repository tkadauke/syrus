import { describe, expect, it } from "vitest"
import { toRomanDate } from "./romanCalendar"

describe("toRomanDate", () => {
  describe("Kalends (1st of each month)", () => {
    it("returns Kal. on the 1st", () => {
      expect(toRomanDate("2025-01-01")).toBe("Kal. Ian.")
      expect(toRomanDate("2025-03-01")).toBe("Kal. Mart.")
      expect(toRomanDate("2025-07-01")).toBe("Kal. Iul.")
      expect(toRomanDate("2025-12-01")).toBe("Kal. Dec.")
    })
  })

  describe("Nones — regular months (5th)", () => {
    it("returns Non. on the 5th for regular months", () => {
      expect(toRomanDate("2025-01-05")).toBe("Non. Ian.")
      expect(toRomanDate("2025-02-05")).toBe("Non. Feb.")
      expect(toRomanDate("2025-04-05")).toBe("Non. Apr.")
      expect(toRomanDate("2025-06-05")).toBe("Non. Iun.")
      expect(toRomanDate("2025-08-05")).toBe("Non. Aug.")
      expect(toRomanDate("2025-09-05")).toBe("Non. Sept.")
      expect(toRomanDate("2025-11-05")).toBe("Non. Nov.")
      expect(toRomanDate("2025-12-05")).toBe("Non. Dec.")
    })
  })

  describe("Nones — late months (7th): March, May, July, October", () => {
    it("returns Non. on the 7th for late-Nones months", () => {
      expect(toRomanDate("2025-03-07")).toBe("Non. Mart.")
      expect(toRomanDate("2025-05-07")).toBe("Non. Mai.")
      expect(toRomanDate("2025-07-07")).toBe("Non. Iul.")
      expect(toRomanDate("2025-10-07")).toBe("Non. Oct.")
    })

    it("does NOT return Non. on the 5th for late-Nones months", () => {
      expect(toRomanDate("2025-03-05")).not.toBe("Non. Mart.")
      expect(toRomanDate("2025-05-05")).not.toBe("Non. Mai.")
    })
  })

  describe("Ides — regular months (13th)", () => {
    it("returns Id. on the 13th for regular months", () => {
      expect(toRomanDate("2025-01-13")).toBe("Id. Ian.")
      expect(toRomanDate("2025-02-13")).toBe("Id. Feb.")
      expect(toRomanDate("2025-04-13")).toBe("Id. Apr.")
      expect(toRomanDate("2025-06-13")).toBe("Id. Iun.")
      expect(toRomanDate("2025-08-13")).toBe("Id. Aug.")
      expect(toRomanDate("2025-09-13")).toBe("Id. Sept.")
      expect(toRomanDate("2025-11-13")).toBe("Id. Nov.")
      expect(toRomanDate("2025-12-13")).toBe("Id. Dec.")
    })
  })

  describe("Ides — late months (15th): March, May, July, October", () => {
    it("returns Id. on the 15th for late-Ides months", () => {
      expect(toRomanDate("2025-03-15")).toBe("Id. Mart.")
      expect(toRomanDate("2025-05-15")).toBe("Id. Mai.")
      expect(toRomanDate("2025-07-15")).toBe("Id. Iul.")
      expect(toRomanDate("2025-10-15")).toBe("Id. Oct.")
    })

    it("does NOT return Id. on the 13th for late-Ides months", () => {
      expect(toRomanDate("2025-03-13")).not.toBe("Id. Mart.")
      expect(toRomanDate("2025-07-13")).not.toBe("Id. Iul.")
    })
  })

  describe("Pridie (the day before each reference day)", () => {
    it("returns prid. Non. the day before Nones in regular months (4th)", () => {
      expect(toRomanDate("2025-01-04")).toBe("prid. Non. Ian.")
      expect(toRomanDate("2025-02-04")).toBe("prid. Non. Feb.")
      expect(toRomanDate("2025-09-04")).toBe("prid. Non. Sept.")
    })

    it("returns prid. Non. the day before Nones in late months (6th)", () => {
      expect(toRomanDate("2025-03-06")).toBe("prid. Non. Mart.")
      expect(toRomanDate("2025-05-06")).toBe("prid. Non. Mai.")
      expect(toRomanDate("2025-07-06")).toBe("prid. Non. Iul.")
      expect(toRomanDate("2025-10-06")).toBe("prid. Non. Oct.")
    })

    it("returns prid. Id. the day before Ides in regular months (12th)", () => {
      expect(toRomanDate("2025-01-12")).toBe("prid. Id. Ian.")
      expect(toRomanDate("2025-04-12")).toBe("prid. Id. Apr.")
      expect(toRomanDate("2025-11-12")).toBe("prid. Id. Nov.")
    })

    it("returns prid. Id. the day before Ides in late months (14th)", () => {
      expect(toRomanDate("2025-03-14")).toBe("prid. Id. Mart.")
      expect(toRomanDate("2025-05-14")).toBe("prid. Id. Mai.")
      expect(toRomanDate("2025-07-14")).toBe("prid. Id. Iul.")
      expect(toRomanDate("2025-10-14")).toBe("prid. Id. Oct.")
    })

    it("returns prid. Kal. on the last day of each month", () => {
      expect(toRomanDate("2025-01-31")).toBe("prid. Kal. Feb.")
      expect(toRomanDate("2025-02-28")).toBe("prid. Kal. Mart.")
      expect(toRomanDate("2025-03-31")).toBe("prid. Kal. Apr.")
      expect(toRomanDate("2025-04-30")).toBe("prid. Kal. Mai.")
      expect(toRomanDate("2025-12-31")).toBe("prid. Kal. Ian.")
    })

    it("returns prid. Kal. on Feb 29 in a leap year", () => {
      expect(toRomanDate("2024-02-29")).toBe("prid. Kal. Mart.")
    })
  })

  describe("Ordinary days", () => {
    it("counts down to Nones with ante diem", () => {
      // Jan 2: 5 - 2 + 1 = 4 → a.d. IV Non.
      expect(toRomanDate("2025-01-02")).toBe("a.d. IV Non. Ian.")
      // Jan 3: 5 - 3 + 1 = 3 → a.d. III Non.
      expect(toRomanDate("2025-01-03")).toBe("a.d. III Non. Ian.")
    })

    it("counts down to Nones in late-Nones months", () => {
      // Mar 3: 7 - 3 + 1 = 5 → a.d. V Non.
      expect(toRomanDate("2025-03-03")).toBe("a.d. V Non. Mart.")
      // Mar 5: 7 - 5 + 1 = 3 → a.d. III Non.
      expect(toRomanDate("2025-03-05")).toBe("a.d. III Non. Mart.")
    })

    it("counts down to Ides with ante diem", () => {
      // Jan 6: 13 - 6 + 1 = 8 → a.d. VIII Id.
      expect(toRomanDate("2025-01-06")).toBe("a.d. VIII Id. Ian.")
      // Jan 7: 13 - 7 + 1 = 7 → a.d. VII Id.
      expect(toRomanDate("2025-01-07")).toBe("a.d. VII Id. Ian.")
    })

    it("counts down to Ides in late-Ides months", () => {
      // Mar 10: 15 - 10 + 1 = 6 → a.d. VI Id.
      expect(toRomanDate("2025-03-10")).toBe("a.d. VI Id. Mart.")
      // Jul 8: 15 - 8 + 1 = 8 → a.d. VIII Id.
      expect(toRomanDate("2025-07-08")).toBe("a.d. VIII Id. Iul.")
    })

    it("counts down to Kalends of next month with ante diem", () => {
      // Jan 14: 31 - 14 + 2 = 19 → a.d. XIX Kal. Feb.
      expect(toRomanDate("2025-01-14")).toBe("a.d. XIX Kal. Feb.")
      // Mar 25: 31 - 25 + 2 = 8 → a.d. VIII Kal. Apr.
      expect(toRomanDate("2025-03-25")).toBe("a.d. VIII Kal. Apr.")
      // Dec 30: 31 - 30 + 2 = 3 → a.d. III Kal. Ian.
      expect(toRomanDate("2025-12-30")).toBe("a.d. III Kal. Ian.")
    })

    it("handles February correctly (non-leap year)", () => {
      // Feb 27: 28 - 27 + 2 = 3 → a.d. III Kal. Mart.
      expect(toRomanDate("2025-02-27")).toBe("a.d. III Kal. Mart.")
      // Feb 6: 13 - 6 + 1 = 8 → a.d. VIII Id. Feb.
      expect(toRomanDate("2025-02-06")).toBe("a.d. VIII Id. Feb.")
    })

    it("handles February correctly in a leap year", () => {
      // Feb 27 in 2024 (leap): 29 - 27 + 2 = 4 → a.d. IV Kal. Mart.
      expect(toRomanDate("2024-02-27")).toBe("a.d. IV Kal. Mart.")
    })
  })

  describe("Invalid input", () => {
    it("returns empty string for empty string", () => {
      expect(toRomanDate("")).toBe("")
    })

    it("returns empty string for null", () => {
      expect(toRomanDate(null)).toBe("")
    })

    it("returns empty string for undefined", () => {
      expect(toRomanDate(undefined)).toBe("")
    })

    it("returns empty string for unparseable dates", () => {
      expect(toRomanDate("not-a-date")).toBe("")
      expect(toRomanDate("hello world")).toBe("")
    })
  })
})
