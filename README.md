# Docker Images Pusher

使用Github Action将国外的Docker镜像转存到阿里云私有仓库，供国内服务器使用，免费易用<br>
- 支持DockerHub, gcr.io, k8s.io, ghcr.io等任意仓库<br>
- 支持最大40GB的大型镜像<br>
- 使用阿里云的官方线路，速度快<br>

视频教程：https://www.bilibili.com/video/BV1Zn4y19743/

作者：**[技术爬爬虾](https://github.com/tech-shrimp/me)**<br>
B站，抖音，Youtube全网同名，转载请注明作者<br>

## 使用方式


### 配置阿里云
登录阿里云容器镜像服务<br>
https://cr.console.aliyun.com/<br>
启用个人实例，创建一个命名空间（**ALIYUN_NAME_SPACE**）
![](/doc/命名空间.png)

访问凭证–>获取环境变量<br>
用户名（**ALIYUN_REGISTRY_USER**)<br>
密码（**ALIYUN_REGISTRY_PASSWORD**)<br>
仓库地址（**ALIYUN_REGISTRY**）<br>

![](/doc/用户名密码.png)


### Fork本项目
Fork本项目<br>
#### 启动Action
进入您自己的项目，点击Action，启用Github Action功能<br>
#### 配置环境变量
进入Settings->Secret and variables->Actions->New Repository secret
![](doc/配置环境变量.png)
将上一步的**四个值**<br>
ALIYUN_NAME_SPACE,ALIYUN_REGISTRY_USER，ALIYUN_REGISTRY_PASSWORD，ALIYUN_REGISTRY<br>
配置成环境变量

### 添加镜像
打开images.txt文件，添加你想要的镜像 
可以加tag，也可以不用(默认latest)<br>
可添加 --platform=xxxxx 的参数指定镜像架构<br>
可使用 k8s.gcr.io/kube-state-metrics/kube-state-metrics 格式指定私库<br>
可使用 #开头作为注释<br>
![](doc/images.png)
文件提交后，自动进入Github Action构建

### 使用镜像
回到阿里云，镜像仓库，点击任意镜像，可查看镜像状态。(可以改成公开，拉取镜像免登录)
![](doc/开始使用.png)

在国内服务器pull镜像, 例如：<br>
```
docker pull registry.cn-hangzhou.aliyuncs.com/shrimp-images/alpine
```
registry.cn-hangzhou.aliyuncs.com 即 ALIYUN_REGISTRY(阿里云仓库地址)<br>
shrimp-images 即 ALIYUN_NAME_SPACE(阿里云命名空间)<br>
alpine 即 阿里云中显示的镜像名<br>

### 多架构
需要在images.txt中用 --platform=xxxxx手动指定镜像架构
指定后的架构会以前缀的形式放在镜像名字前面
![](doc/多架构.png)

### 镜像重名
程序自动判断是否存在名称相同, 但是属于不同命名空间的情况。
如果存在，会把命名空间作为前缀加在镜像名称前。
例如:
```
xhofe/alist
xiaoyaliu/alist
```
![](doc/镜像重名.png)

### 定时执行
修改/.github/workflows/docker.yaml文件
添加 schedule即可定时执行(此处cron使用UTC时区)
![](doc/定时执行.png)

## Fork 优化说明

以下内容为本 Fork 新增功能，原作者文档保持不变。

### 统一镜像命名

- 移除源镜像 registry 域名。
- 保留完整仓库路径，并将 `/` 转为 `_`。
- Docker 官方单段镜像名保持不变，不添加 `library_`。
- platform 转换后追加到目标仓库名末尾。

```text
name/image:tag
  -> <registry>/<namespace>/name_image:tag

ghcr.io/immich-app/immich-server:release
  -> <registry>/<namespace>/immich-app_immich-server:release

--platform=linux/arm64 xiaoyaliu/alist
  -> <registry>/<namespace>/xiaoyaliu_alist_linux_arm64:latest

--platform linux/arm/v7 xiaoyaliu/alist
  -> <registry>/<namespace>/xiaoyaliu_alist_linux_arm_v7:latest
```

### Platform 支持

支持以下两种参数写法：

```text
--platform=linux/arm64 image
--platform linux/arm64 image
```

platform 必须是 `os/arch` 或 `os/arch/variant` 格式，每段不能为空。三段格式会正确传递 Skopeo 的 `--override-variant`。

### Digest 镜像支持

支持 `@sha256:<64位十六进制>`。Docker 操作仍使用完整源引用，目标 tag 追加 digest 前 12 位，避免不同 digest 覆盖同一 tag。

```text
ghcr.io/foo/bar@sha256:0123456789abcdef...
  -> <registry>/<namespace>/foo_bar:latest-sha256-0123456789ab

ghcr.io/foo/bar:v1@sha256:0123456789abcdef...
  -> <registry>/<namespace>/foo_bar:v1-sha256-0123456789ab
```

非 `sha256` 算法或格式错误的 digest 会被拒绝。

### 智能增量同步

- 使用 Skopeo 获取源镜像和目标镜像在指定平台下的 config blob。
- config digest 相同则跳过。
- digest 不同或目标不存在时自动重新同步。
- `latest` 等可变 tag 内容变化后可自动刷新。
- 源镜像检查失败时输出原因并重试一次。

### 失败处理

- 单个镜像失败后继续处理剩余镜像。
- 最后汇总成功、跳过和失败数量。
- 任一镜像失败时，工作流最终返回失败状态。
- 每个镜像处理后清理本地镜像，避免磁盘占用持续增加。

### Workflow 安全与触发优化

- Docker 登录使用 `--password-stdin`。
- Secrets 只注入需要它们的步骤。
- GitHub Actions 权限限制为 `contents: read`。
- 第三方磁盘扩容 Action 固定 commit SHA。
- `main` 分支中以下文件变化时自动触发：
  - `images.txt`
  - `scripts/**`
  - `.github/workflows/docker.yaml`
- 保留 `workflow_dispatch` 手动触发。

### 测试与维护

- 镜像解析和同步流程拆分为独立 Shell 脚本。
- 增加命名、platform、digest、增量同步、失败继续和安全登录测试。
- 脚本兼容 GitHub Runner 使用的 Bash。
