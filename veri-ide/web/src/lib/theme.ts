export type Theme = "dark" | "light";

const STORAGE_KEY = "veride.theme";

export function readTheme(): Theme {
  try {
    return localStorage.getItem(STORAGE_KEY) === "light" ? "light" : "dark";
  } catch {
    // Private mode / disabled storage: the dark palette is the safe default.
    return "dark";
  }
}

/** The palette lives in CSS variables keyed off this attribute, so setting it
    is all a theme change takes -- no React re-render of every panel needed. */
export function writeTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    /* ignored */
  }
}
