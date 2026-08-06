# 镜像同步与命名优化设计

## 目标

在保留 GitHub Actions + Docker + 阿里云 ACR 方案的前提下，简化同步流程，统一目标镜像命名，支持增量同步，并让命名逻辑可独立测试。

管理页面、Webhook 通知、定时任务不在本次范围内。

## 输入格式

`images.txt` 每行包含一个镜像，可选 Docker pull platform 参数：

```text
nginx:latest
ghcr.io/immich-app/immich-server:release
--platform=linux/arm64 xiaoyaliu/alist
--platform linux/amd64 quay.io/example/team/image:v1
```

空行和首个非空白字符为 `#` 的行被忽略。

## 命名规则

1. 从源镜像引用中移除 digest 用于命名，但完整原始引用（含 digest）仍保留给 Docker pull/tag 使用。
2. 识别并移除 registry 部分。首段包含 `.`、包含端口，或为 `localhost` 时视为 registry。
3. 保留 registry 后的完整仓库路径，并将 `/` 替换为 `_`。
4. 未指定 tag 时使用 `latest`。
5. 指定 platform 时，将 `/` 替换为 `_`，追加到仓库名末尾。platform 必须是标准的 `os/arch` 或 `os/arch/variant` 格式（恰好 2 段或 3 段，每段非空），否则拒绝该行；例如 `linux/`、`/amd64`、四段格式均无效。
6. Docker 官方镜像保持原仓库名，不添加 `library_`。
7. 源引用带 `@sha256:<64位十六进制>` digest 时，目标 tag 在原 tag（或默认 `latest`）后追加 `-sha256-<digest 前12位>`，避免不同 digest 覆盖同一个可变 tag。digest 不是合法的 `sha256:<64位十六进制>` 格式时直接拒绝该行。

示例：

```text
ghcr.io/immich-app/immich-server:release
-> $ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/immich-app_immich-server:release

--platform=linux/arm64 xiaoyaliu/alist
-> $ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/xiaoyaliu_alist_linux_arm64:latest

--platform linux/arm/v7 xiaoyaliu/alist
-> $ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/xiaoyaliu_alist_linux_arm_v7:latest

nginx:latest
-> $ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/nginx:latest

ghcr.io/foo/bar@sha256:0123456789abcdef...
-> $ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/foo_bar:latest-sha256-0123456789ab
```

## 结构

### GitHub Actions workflow

`.github/workflows/docker.yaml` 负责：

- 在 `images.txt` 推送到 `main` 时触发，也允许手动触发。
- 释放 runner 磁盘空间并重启 Docker。
- 使用 `--password-stdin` 登录阿里云 ACR。
- 调用同步脚本并保留其退出状态。

### 同步脚本

`scripts/sync-images.sh` 负责：

- 启动时校验 `skopeo` 是否在 `PATH` 中，缺失立即报错退出，不会静默退化为全量推送。
- 读取和验证 `images.txt`。
- 调用纯命名函数生成源镜像、目标镜像和 platform 参数。
- 用 `skopeo inspect --raw --config` 分别获取源镜像和目标镜像的 config blob，并计算 sha256 摘要；指定 `--platform` 时在 `inspect` 前追加 `--override-os`/`--override-arch`，三段格式（含 variant）时再追加 `--override-variant`。
- 源镜像 inspect 失败时先输出具体 Skopeo stderr 原因，等待 `SKOPEO_RETRY_DELAY`（默认 2 秒，可覆盖用于测试）后重试一次；第二次仍失败则打印最终原因、记为该镜像失败，不当作目标缺失处理。
- 目标 inspect 失败视为目标不存在（不重试），并打印一行含具体原因的可诊断提示。
- 成功但返回空 config blob 视为失败，避免对空内容计算出误导性的摘要。
- 两者摘要相同则跳过；不同或目标不存在则依次 pull、tag、push 完成同步/刷新。
- 每个镜像完成后清理源和目标镜像，避免磁盘累计占用。
- 统计成功、跳过和失败数量。

### 命名函数

`scripts/image-name.sh` 只负责解析和命名，不执行网络或 Docker 操作。同步脚本和测试共同使用它，避免 YAML 内重复复杂字符串处理。

## 错误处理

- 单个镜像解析或同步失败时记录错误，继续处理后续镜像。
- 所有镜像处理后打印成功、跳过、失败汇总。
- 只要存在失败，脚本和 workflow 最终退出非零。
- 登录失败、缺少必要环境变量或找不到输入文件时立即失败。
- 清理失败仅输出警告，不覆盖同步结果。

## 测试

`tests/image-name-test.sh` 使用 Bash 断言覆盖：

- 不同 registry 的移除规则。
- 多级仓库路径拍平。
- 显式 tag 和默认 `latest`。
- `--platform=value` 与 `--platform value`。
- platform 后缀，包括 `os/arch` 与 `os/arch/variant` 两种合法段数，以及非法段数/空段的拒绝。
- digest 输入。
- 官方单段镜像名。
- 带端口 registry 与 localhost。
- 空行、注释和无效输入。

测试先于实现编写并确认失败；实现完成后运行命名测试和 workflow YAML 静态检查。

## 不兼容变化

现有“仅重名时添加 namespace”和“platform 前缀”规则被替换：

- 所有多段仓库路径始终拍平，命名稳定，不依赖 `images.txt` 其他内容。
- platform 从仓库名前缀改为后缀。
- 目标 tag 是否重新同步取决于源和目标 config blob 摘要是否一致，而非目标 tag 是否已存在；`latest` 等可变 tag 会随源镜像内容自动刷新，无需手动删除 ACR 中的目标 tag。
