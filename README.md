# StreamerHelper Infra

StreamerHelper 的部署与运行控制仓库。这里维护 Docker Compose 编排、配置生成、数据库迁移和版本更新入口。

[快速开始](#快速开始) · [服务拓扑](#服务拓扑) · [命令参考](#命令参考) · [配置](#配置) · [本地联调](#本地联调) · [部署手册](./DEPLOY.md)

## 仓库职责

| 范围 | 内容 |
| --- | --- |
| 配置 | 生成并校验 `settings.json` 与容器环境变量 |
| 编排 | 管理 PostgreSQL、Redis、MinIO、Browser、抖音解析器、后端、前端和 Nginx |
| 数据库 | 在应用启动或更新前执行 TypeORM 迁移 |
| 发布 | 拉取指定版本镜像并重建应用容器 |
| 开发 | 从相邻源码仓库构建镜像，启动本地联调环境 |

业务代码分别位于 [web-server](https://github.com/StreamerHelper/web-server) 和 [web](https://github.com/StreamerHelper/web)；匿名抖音解析器源码位于 [`douyin-resolver`](./douyin-resolver)，产品说明见 [StreamerHelper](https://github.com/StreamerHelper/StreamerHelper)。

## 快速开始

### 环境要求

| 依赖 | 最低版本或建议 |
| --- | --- |
| Docker Engine | 20.10+ |
| Docker Compose | v2 |
| Node.js | 18+ |
| jq | 任意受支持版本 |
| 内存 | 4 GB 以上 |

在 Apple Silicon macOS 上默认优先使用 OrbStack；其他环境默认使用 Docker。运行时可以在配置中调整。

```bash
git clone https://github.com/StreamerHelper/infra.git
cd infra

npm ci
./bin/configure init
RELEASE_VERSION=v1.2.3 # 替换为要安装的已发布版本
./bin/control update all "$RELEASE_VERSION"
```

首次安装必须选择明确的已发布版本；`update all` 会启动基础设施、执行数据库迁移、启动应用并写入 release pin。此后 `control up` 才用于按该 pin 重启整套服务。

启动后可访问：

| 入口 | 默认地址 |
| --- | --- |
| Web UI | http://localhost:7080 |
| API | http://localhost:7080/api |
| Bull Board | http://localhost:7080/ui |
| MinIO Console | http://localhost:7091 |

生产主机、安全配置、备份与升级说明见 [DEPLOY.md](./DEPLOY.md)。

## 服务拓扑

外部请求由 Nginx 统一接入，应用容器只在 Compose 网络内暴露服务端口。

| 服务 | 容器内端口 | 默认宿主机端口 | 用途 |
| --- | ---: | ---: | --- |
| Nginx | 80 / 443 | 7080 / 7443 | Web、API 和队列面板入口 |
| Frontend | 3000 | — | Next.js 管理界面 |
| Backend | 7001 | — | API、调度和后台任务 |
| Browser | 9222 | — | 抖音网页登录与二次验证 |
| Douyin Resolver | 7100 | — | 基于 Biliup 的匿名直播状态与取流解析 |
| PostgreSQL | 5432 | — | 业务数据 |
| Redis | 6379 | — | 缓存与 BullMQ |
| MinIO | 7090 / 7091 | 7090 / 7091 | 对象存储与管理控制台 |

`http.port`、`http.httpsPort` 和 MinIO 端口控制宿主机映射；Backend、Frontend、Browser 与 Douyin Resolver 的内部端口保持固定。Browser 和 Resolver 均不映射宿主机端口，分别使用只与 Backend 共享的专用 bridge 网络，同时保留访问抖音上游所需的出站连接。

## 命令参考

### 配置工具

| 命令 | 作用 |
| --- | --- |
| `./bin/configure init` | 创建初始配置 |
| `./bin/configure edit` | 修改已有配置 |
| `./bin/configure show` | 脱敏显示当前配置 |

### 服务控制

| 命令 | 作用 |
| --- | --- |
| `./bin/control up` | 使用已有 release pin 启动基础设施、迁移数据库并启动应用 |
| `./bin/control down` | 停止全部服务 |
| `./bin/control infra up` | 仅启动 PostgreSQL、Redis 和 MinIO |
| `./bin/control infra down` | 停止基础设施 |
| `./bin/control migrate` | 执行数据库迁移 |
| `./bin/control app up` | 启动应用服务 |
| `./bin/control app down` | 停止应用服务 |
| `./bin/control update app <version>` | 使用明确的不可变版本更新应用镜像 |
| `./bin/control update app <version> --preloaded` | 使用已预载到服务器的四个精确版本镜像更新应用 |
| `./bin/control update infra` | 更新基础设施镜像 |
| `./bin/control update all <version>` | 更新基础设施并使用明确版本更新应用 |
| `./bin/control status` | 查看容器状态 |
| `./bin/control logs [service]` | 持续查看全部或指定服务日志 |

更新应用时会先拉取同一版本的四个应用镜像，在当前服务保持在线时用新 Backend 执行迁移；迁移成功后才重建应用容器。Backend 和 Frontend 健康后，版本会原子写入独立的 release pin，后续 `app down` / `app up` 仍使用该版本。失败恢复会保留更新前的运行状态：原来运行时恢复原 pin 对应的应用，原来停止时只清理可能创建的候选容器并保持停止；`update all` 会把它主动停止应用前的状态传递给同一恢复路径。Browser 或 Resolver 异常只会进入降级状态并保留其它平台能力。PostgreSQL、Redis 和 MinIO 无需随应用更新重启。

`--preloaded` 只跳过 registry pull。它会先确认 Backend、Frontend、Browser 和 Douyin Resolver 的 `ghcr.io/streamerhelper/streamerhelper-<component>:<version>` 精确标签全部存在于本机，之后仍执行同一套迁移、健康检查、release pin 和失败恢复流程；缺少任一镜像时会在迁移和重建前退出。

生产镜像默认发布到 `ghcr.io/streamerhelper`。发布标签必须是 `latest` 以外的新标签。没有 release pin 或 pin 内容损坏时，生产模式的 `app up` / `up` 会明确失败，不会回退到 `latest`；`docker-compose.app.yml` 本身也要求四个应用版本变量非空。生产操作应通过 `bin/control` 执行，它的停止命令在没有 pin 时仍可安全清理容器。首次安装请使用 `update all <version>`，也可以先启动基础设施再运行 `update app <version>`。CI 使用 `github.actor` 和当前工作流的 `GITHUB_TOKEN` 登录 GHCR；tag 事件要求 infra、web-server 和 web 三个仓库存在同名 tag，手动触发时必须明确填写 Backend 与 Frontend 的 tag 或 commit。工作流会记录实际解析出的三个 SHA，并拒绝覆盖已存在的镜像标签；只有 registry 明确返回 manifest 不存在时才允许发布，网络、鉴权或 registry 异常会中止。

本地发布前先运行 `docker login ghcr.io`，再执行 `./build-and-push.sh <version>`。脚本会先确认 GHCR credential 存在并探测四个不可变标签，随后统一构建和推送 `linux/amd64` 与 `linux/arm64`，且不会更新 `latest`。

## 配置

配置工具生成以下本地文件：

| 文件 | 用途 |
| --- | --- |
| `~/.streamer-helper/settings.json` | 后端运行配置 |
| `~/.streamer-helper/.docker-env` | Compose 环境变量 |
| `~/.streamer-helper/release-version` | 当前应用发布版本；非密钥，由首次安装或成功更新原子写入 |

字段定义见 [settings.example.json](./settings.example.json) 和 [settings.schema.json](./settings.schema.json)。配置覆盖数据库、Redis、对象存储、录制、轮询、上传、通知与容器运行时。

配置文件包含密钥和访问凭据，不应提交到版本控制。排查配置时使用 `./bin/configure show` 获取脱敏输出。
加载旧配置时会先验证 JSON，再原子删除已废弃的 `platforms.douyin.cookie`；升级保留文件权限、`userAgent` 和其它字段，日志不会输出旧 Cookie 值。

## 本地联调

源码构建模式要求三个仓库处于同一父目录：

```text
streamer-helper/
├── infra/
│   └── douyin-resolver/
├── web-server/
└── web/
```

常用命令：

| 命令 | 作用 |
| --- | --- |
| `./bin/control dev up` | 构建并启动本地源码 |
| `./bin/control dev down` | 停止开发环境 |
| `./bin/control dev restart` | 重启开发环境 |
| `./bin/control dev build [service]` | 构建全部或指定本地镜像 |
| `npm test` | 验证 release pin、预载更新、运行状态恢复、GHCR 发布预检、Compose 必填版本与旧配置清理 |

开发模式使用本地镜像，不要求 release pin。

后端与前端各自的开发命令见 [web-server README](https://github.com/StreamerHelper/web-server#readme) 和 [web README](https://github.com/StreamerHelper/web#readme)。

## 运维入口

```bash
# 查看总体状态
./bin/control status

# 跟踪后端日志
./bin/control logs backend

# 仅更新应用，不重启数据服务
./bin/control update app v1.2.3

# 镜像已由其它机器预载到服务器时
./bin/control update app v1.2.3 --preloaded
```

部署前应建立 PostgreSQL 与 MinIO 的独立备份。具体备份、恢复和故障排查流程统一维护在 [DEPLOY.md](./DEPLOY.md)。

## License

[MIT](https://github.com/StreamerHelper/StreamerHelper/blob/main/LICENSE)
