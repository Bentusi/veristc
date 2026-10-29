/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        ide: {
          bg: "#1e1e1e",
          sidebar: "#252526",
          activity: "#333333",
          panel: "#1e1e1e",
          status: "#007acc",
          border: "#3c3c3c",
          text: "#cccccc",
          textDim: "#858585",
          accent: "#007acc",
          hover: "#2a2d2e",
          selected: "#37373d",
        },
      },
    },
  },
  plugins: [],
};
