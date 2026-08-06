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
可用 `--platform=linux/arm64 镜像名` 或 `--platform linux/arm64 镜像名` 指定镜像架构，也支持带 variant 的三段格式，如 `--platform linux/arm/v7 镜像名`<br>
可使用 k8s.gcr.io/kube-state-metrics/kube-state-metrics 格式指定私库<br>
可使用 #开头作为注释<br>
![](doc/images.png)
`main` 分支中的 `images.txt`、`scripts/**` 或 `.github/workflows/docker.yaml` 发生变更时，会自动触发 GitHub Action；也可以通过 `workflow_dispatch` 手动触发。

同步时会将镜像路径中的 `/` 转为 `_`，仓库域名不写入目标镜像名。例如：
```
name/image:tag
  -> <registry>/<namespace>/name_image:tag

ghcr.io/immich-app/immich-server:release
  -> <registry>/<namespace>/immich-app_immich-server:release

--platform=linux/arm64 xiaoyaliu/alist
  -> <registry>/<namespace>/xiaoyaliu_alist_linux_arm64:latest

ghcr.io/foo/bar@sha256:0123456789abcdef...
  -> <registry>/<namespace>/foo_bar:latest-sha256-0123456789ab

ghcr.io/foo/bar:v1@sha256:0123456789abcdef...
  -> <registry>/<namespace>/foo_bar:v1-sha256-0123456789ab
```

同步前会用 Skopeo 分别获取源镜像和目标镜像（当前运行平台，或 `--platform` 指定平台）的 config blob 并计算 sha256：两者相同则跳过，不同则自动重新 pull/tag/push 刷新，目标不存在时也会直接同步。因此 `latest` 等可变 tag 会随源镜像内容自动刷新，无需手动删除 ACR 中的目标 tag。若源镜像本身无法被 Skopeo 检查（例如引用错误或临时不可访问），该镜像会被记为失败并继续处理其余镜像。

单个镜像同步失败后，程序会继续处理剩余镜像，但全部处理完后仍以失败状态退出，使 Action 明确标记失败。

`images.txt` 中的镜像引用可以带 `@sha256:<64位十六进制>` digest：Docker 拉取仍使用完整的原始引用（含 digest），但目标 tag 会在原 tag（未指定时为 `latest`）后追加 `-sha256-<digest 前12位>`，避免多个 digest 覆盖同一个可变 tag。非 `sha256` 算法或格式不合法的 digest 会被直接拒绝。

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
需要在images.txt中用 `--platform=linux/arm64 镜像名` 或 `--platform linux/arm64 镜像名` 手动指定镜像架构，格式为标准的 `os/arch` 或 `os/arch/variant`（如 `linux/arm/v7`），恰好 2 段或 3 段，每段不能为空，否则会被拒绝。
架构会转换为目标镜像名的后缀，例如 `xiaoyaliu_alist_linux_arm64:latest`；三段格式的 variant 同样会拼接到后缀，例如 `linux/arm/v7` -> `xiaoyaliu_alist_linux_arm_v7:latest`。
![](doc/多架构.png)

### 镜像重名
镜像路径始终会用下划线连接，因此不同命名空间的同名镜像会得到不同目标名称。例如：
```
xhofe/alist -> xhofe_alist:latest
xiaoyaliu/alist -> xiaoyaliu_alist:latest
```
![](doc/镜像重名.png)

### 定时执行
修改/.github/workflows/docker.yaml文件
添加 schedule即可定时执行(此处cron使用UTC时区)
![](doc/定时执行.png)
