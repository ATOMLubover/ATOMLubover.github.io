import js from "@eslint/js";
import ts from "typescript-eslint";
import globals from "globals";
import prettier from "eslint-config-prettier";
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

	prettier,
);
