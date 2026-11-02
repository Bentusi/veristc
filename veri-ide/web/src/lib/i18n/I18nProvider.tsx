import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { translations, type Locale, type TranslationKey } from "./translations";

const STORAGE_KEY = "veride.locale";

function readLocale(): Locale {
  const stored = window.localStorage.getItem(STORAGE_KEY);
  if (stored === "zh-CN" || stored === "en") return stored;
  return "zh-CN";
}

function writeLocale(locale: Locale) {
  window.localStorage.setItem(STORAGE_KEY, locale);
}

interface I18nApi {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: TranslationKey, args?: Record<string, string | number>) => string;
}

const I18nContext = createContext<I18nApi | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(readLocale);

  const setLocale = useCallback((next: Locale) => {
    writeLocale(next);
    setLocaleState(next);
  }, []);

  const t = useCallback(
    (key: TranslationKey, args?: Record<string, string | number>): string => {
      let text = (translations[locale][key] ?? translations["zh-CN"][key] ?? key) as string;
      if (args) {
        for (const [k, v] of Object.entries(args)) {
          text = text.replace(`{${k}}`, String(v));
        }
      }
      return text;
    },
    [locale],
  );

  const value = useMemo<I18nApi>(() => ({ locale, setLocale, t }), [locale, setLocale, t]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nApi {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used inside I18nProvider");
  return ctx;
}
