import colors from "tailwindcss/colors";

/** @type {import('tailwindcss').Config} */
const hue = (name) => `rgb(var(--ide-hue-${name}) / <alpha-value>)`;

export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        // Every ide.* token is an "R G B" triplet declared in src/index.css so
        // the <alpha-value> slash syntax keeps working under both themes.
        ide: {
          bg: "rgb(var(--ide-bg) / <alpha-value>)",
          sidebar: "rgb(var(--ide-sidebar) / <alpha-value>)",
          activity: "rgb(var(--ide-activity) / <alpha-value>)",
          panel: "rgb(var(--ide-panel) / <alpha-value>)",
          status: "rgb(var(--ide-status) / <alpha-value>)",
          border: "rgb(var(--ide-border) / <alpha-value>)",
          text: "rgb(var(--ide-text) / <alpha-value>)",
          textDim: "rgb(var(--ide-text-dim) / <alpha-value>)",
          accent: "rgb(var(--ide-accent) / <alpha-value>)",
          hover: "rgb(var(--ide-hover) / <alpha-value>)",
          selected: "rgb(var(--ide-selected) / <alpha-value>)",
          // Foreground on a neutral surface: white in dark, near-black in
          // light. Text on a saturated button keeps literal `text-white`.
          strong: "rgb(var(--ide-strong) / <alpha-value>)",
        },
        // Status hues used as *text* on a panel: only those shades become
        // theme variables, so `bg-blue-600` buttons and `/20` tints keep the
        // literal Tailwind values that read fine either way.
        red: { ...colors.red, 200: hue("red"), 300: hue("red"), 400: hue("red") },
        green: { ...colors.green, 300: hue("green"), 400: hue("green"), 500: hue("green") },
        yellow: { ...colors.yellow, 300: hue("yellow"), 400: hue("yellow"), 500: hue("yellow") },
        orange: { ...colors.orange, 300: hue("orange"), 400: hue("orange") },
        blue: { ...colors.blue, 300: hue("blue"), 400: hue("blue") },
        teal: { ...colors.teal, 300: hue("teal") },
        purple: { ...colors.purple, 400: hue("purple") },
        cyan: { ...colors.cyan, 400: hue("cyan") },
      },
    },
  },
  plugins: [],
};
