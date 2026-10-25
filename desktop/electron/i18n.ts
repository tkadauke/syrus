import { app } from "electron"

import { createElectronI18n } from "./i18nRuntime.js"

export const { appLocale, t } = createElectronI18n(() => app.getLocale())
