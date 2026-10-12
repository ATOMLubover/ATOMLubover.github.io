# 事务上下文注入 · 解说幻灯片

基于 [Slidev](https://github.com/slidevjs/slidev)，对应博客 [《优雅处理事务上下文注入的设计范式》](../../src/content/posts/优雅处理事务上下文注入的设计范式.md)。18 页，约 15 分钟，面向熟悉 Rust 基础与数据库事务的读者。

## 运行

沿用博客的 Node.js 26.11.1 和 pnpm 12.11.2，在独立目录管理演示依赖：

```sh
cd slides/transaction-context
pnpm install --frozen-lockfile --allow-scripts=npm:esbuild
pnpm run dev
```

打开 <http://localhost:3030>。方向键或空格推进幻灯片与代码高亮；讲者视图 <http://localhost:3030/presenter> 显示逐页中文讲稿。

## 构建与导出

PowerPoint 文件：[事务上下文注入.pptx](exports/事务上下文注入.pptx)。18 页，页面以图片形式保存，讲稿保留在演讲者备注中；文字与代码不能在 PowerPoint 中单独编辑。

重新导出（macOS 已安装 Google Chrome）：

```sh
pnpm run export:pptx --executable-path '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
```

其他系统可传入本机 Chromium 浏览器路径，或安装 Playwright 浏览器后直接运行 `pnpm run export:pptx`。

```sh
pnpm run build
```

静态演示生成到本目录的 `dist/`。部署至子路径时运行 `pnpm run build --base /slides/transaction-context/`，将产物交给支持 SPA 回退的静态服务器。

PDF 可在现代 Chromium 浏览器打开 <http://localhost:3030/export> 后，通过 Slidev 导出界面生成。参见 [Slidev 导出文档](https://sli.dev/guide/exporting)。

## 内容与维护

- `slides.md`：演示内容、逐步高亮、Mermaid 图与讲稿；每页末尾注释为讲稿。
- `style.css`：深色版式，使用本地中文字体，无远程字体下载。
- `global-top.vue`：署名与页码。
- `vite.config.ts`：独立的 PostCSS 配置，避免继承博客样式处理链。

叙事顺序：转账失败场景 → 显式上下文 → 关联类型 → Nucl → 完整 usecase → 职责与保证范围。代码用于解释接口关系，省略具体后端、导入及部分错误定义，并非独立 Rust 程序。相较原文示意，补全了 `Self::Context`、`Some(&mut *cx)`、闭包成功返回值及事务错误返回类型。

运行方式与语法参考 [Slidev 入门](https://sli.dev/guide/) 和 [语法指南](https://sli.dev/guide/syntax)。
