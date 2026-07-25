# StreamerHelper Infra

StreamerHelper 的部署与运行控制仓库。这里维护 Docker Compose 编排、配置生成、数据库迁移和版本更新入口。

[快速开始](#快速开始) · [服务拓扑](#服务拓扑) · [命令参考](#命令参考) · [配置](#配置) · [本地联调](#本地联调) · [部署手册](./DEPLOY.md)

## 仓库职责

| 范围 | 内容 |
| --- | --- |
| 配置 | 生成并校验 `settings.json` 与容器环境变量 |
| 编排 | 管理 PostgreSQL、Redis、MinIO、后端、前端和 Nginx |
| 数据库 | 在应用启动或更新前执行 TypeORM 迁移 |
| 发布 | 拉取指定版本镜像并重建应用容器 |
| 开发 | 从相邻源码仓库构建镜像，启动本地联调环境 |

业务代码分别位于 [web-server](https://github.com/StreamerHelper/web-server) 和 [web](https://github.com/StreamerHelper/web)；产品说明见 [StreamerHelper](https://github.com/StreamerHelper/StreamerHelper)。

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
./bin/control up
```

`control up` 会依次启动基础设施、执行数据库迁移并启动应用服务。

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
| PostgreSQL | 5432 | — | 业务数据 |
| Redis | 6379 | — | 缓存与 BullMQ |
| MinIO | 7090 / 7091 | 7090 / 7091 | 对象存储与管理控制台 |

`http.port`、`http.httpsPort` 和 MinIO 端口控制宿主机映射；Backend、Frontend 与 Browser 的内部端口保持固定。

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
| `./bin/control up` | 启动基础设施、迁移数据库并启动应用 |
| `./bin/control down` | 停止全部服务 |
| `./bin/control infra up` | 仅启动 PostgreSQL、Redis 和 MinIO |
| `./bin/control infra down` | 停止基础设施 |
| `./bin/control migrate` | 执行数据库迁移 |
| `./bin/control app up` | 启动应用服务 |
| `./bin/control app down` | 停止应用服务 |
| `./bin/control update app [version]` | 更新应用镜像并重建应用服务 |
| `./bin/control update infra` | 更新基础设施镜像 |
| `./bin/control update all [version]` | 更新全部镜像 |
| `./bin/control status` | 查看容器状态 |
| `./bin/control logs [service]` | 持续查看全部或指定服务日志 |

更新应用时会先拉取镜像，再停止应用、执行迁移并重建应用容器。PostgreSQL、Redis 和 MinIO 无需随应用更新重启。

## 配置

配置工具生成以下本地文件：

| 文件 | 用途 |
| --- | --- |
| `~/.streamer-helper/settings.json` | 后端运行配置 |
| `~/.streamer-helper/.docker-env` | Compose 环境变量 |

字段定义见 [settings.example.json](./settings.example.json) 和 [settings.schema.json](./settings.schema.json)。配置覆盖数据库、Redis、对象存储、录制、轮询、上传、通知与容器运行时。

配置文件包含密钥和访问凭据，不应提交到版本控制。排查配置时使用 `./bin/configure show` 获取脱敏输出。

## 本地联调

源码构建模式要求三个仓库处于同一父目录：

```text
streamer-helper/
├── infra/
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

后端与前端各自的开发命令见 [web-server README](https://github.com/StreamerHelper/web-server#readme) 和 [web README](https://github.com/StreamerHelper/web#readme)。

## 运维入口

```bash
# 查看总体状态
./bin/control status

# 跟踪后端日志
./bin/control logs backend

# 仅更新应用，不重启数据服务
./bin/control update app
```

部署前应建立 PostgreSQL 与 MinIO 的独立备份。具体备份、恢复和故障排查流程统一维护在 [DEPLOY.md](./DEPLOY.md)。

## License

[MIT](https://github.com/StreamerHelper/StreamerHelper/blob/main/LICENSE)
