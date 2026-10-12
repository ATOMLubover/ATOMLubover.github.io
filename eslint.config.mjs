import js from "@eslint/js";
import ts from "typescript-eslint";
import globals from "globals";
import prettier from "eslint-config-prettier";
import svelte from "eslint-plugin-svelte";
import astro from "eslint-plugin-astro";
export default ts.config(
	{
		ignores: [
			"node_modules/**",
			"dist/**",
			"build/**",
			".astro/**",
			".svelte-kit/**",
			"slides/**",
			"exports/**",
		],
	},
	js.configs.recommended,
	...ts.configs.recommended,
	{ languageOptions: { globals: { ...globals.node, ...globals.browser } } },
	...svelte.configs["flat/recommended"],
	{
		files: ["**/*.svelte"],
		languageOptions: { parserOptions: { parser: ts.parser } },
	},
	...astro.configs.recommended,
	// CSS variables are also consumed by Tailwind arbitrary-value classes and scripts.
	{
		files: ["src/components/PostCard.astro", "src/layouts/Layout.astro"],
		rules: { "astro/no-unused-define-vars-in-style": "off" },
	},
	{
		rules: {
			"@typescript-eslint/no-unused-vars": [
				"error",
				{ argsIgnorePattern: "^_" },
			],
		},
	},
	{
		files: ["**/*.cjs"],
		rules: { "@typescript-eslint/no-require-imports": "off" },
	},
	prettier,
);
