# Personal Blog

基于 [Fuwari](https://github.com/saicaca/fuwari) 的 Astro 静态博客，使用 Deno 管理依赖和运行任务。

## 开发

需要 Deno 2.9.6，以及运行快捷命令用的 just。

```sh
deno install --frozen --allow-scripts=npm:esbuild,npm:sharp
deno task dev
```

开发地址：<http://localhost:4321>。

## 常用命令

```sh
deno task check             # Astro 类型检查
deno task build             # 构建站点并生成 Pagefind 搜索索引
deno task preview           # 预览 dist 中的构建产物
deno task new-post my-post  # 创建文章
deno task format            # 格式化源码
deno task lint              # 检查源码规范
```

依赖声明在 `package.json`，锁定在 `deno.lock`，任务定义在 `deno.json`。所有任务均由 Deno 执行。

## 部署

站点地址：https://atomlubover.github.io/ 。`main` 分支保存源码，GitHub Actions 构建并发布 `dist`，无需提交构建产物。

首次安装依赖运行 `just install`。日常修改后：

```sh
git add <要发布的文件>
git commit -m "docs: update blog"
just deploy
```

`just deploy` 要求位于 `main`、工作区干净且 `origin` 指向本博客仓库，然后运行类型检查、构建并普通推送。推送后等待 GitHub Actions 的 **Build and Deploy** 成功即完成上线。命令不会自动提交，也不会强制覆盖远端。

仓库 Settings → Pages → Source 使用 **GitHub Actions**。如需重新发布已提交版本，可在 Actions 中手动运行 **Build and Deploy**。恢复旧版本可用 `git revert` 创建回退提交后再次运行 `just deploy`。

本地预览使用 `just build` 和 `just preview`。

## 配置和内容

- `src/config.ts`：站点标题、语言、头像、导航和主题。
- `astro.config.mjs`：正式站点地址和路径前缀，当前部署在根路径。
- `src/content/posts/`：Markdown 文章，当前包含模板示例。
- `src/content/spec/about.md`：关于页面。
- `public/`：静态资源。

当前保留 Fuwari 示例配置和内容。模板功能说明见 [中文文档](docs/README.zh-CN.md)；其中的 pnpm 命令请使用上述 Deno 命令替代。

构建结果位于 `dist/`，可部署至静态托管服务。GitHub Actions 使用 Deno 执行检查和构建。

Fuwari 采用 MIT 许可，详见 [LICENSE](LICENSE)。
