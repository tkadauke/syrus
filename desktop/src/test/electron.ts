let locale = "en"

export const app = {
  getLocale: () => locale
}

export function setElectronLocale(value: string) {
  locale = value
}
