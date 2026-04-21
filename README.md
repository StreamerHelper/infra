# StreamerHelper Infrastructure

StreamerHelper 的 Docker 部署配置和管理工具。

## 架构概览

```
                    ┌─────────────┐
                    │   Nginx     │ :7080/:7443
                    │  (反向代理)  │
                    └──────┬──────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
┌──────────┐        ┌──────────┐        ┌──────────┐
│ Frontend │        │ Backend  │        │ Bull     │
│ (Next.js)│        │(MidwayJS)│        │ Board    │
│  :3000   │        │  :7001   │        │  /ui/    │
└──────────┘        └────┬─────┘        └──────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
  ┌──────────┐    ┌──────────┐    ┌──────────┐
  │PostgreSQL│    │  Redis   │    │  MinIO   │
  │  :5432   │    │  :6379   │    │:7090/7091│
  └──────────┘    └──────────┘    └──────────┘
```

## 文件结构

```
infra/
├── bin/
│   ├── configure              # 交互式配置工具 (Node.js)
│   └── control                # 容器管理脚本 (Bash)
├── docker-compose.infra.yml   # 基础设施: PostgreSQL, Redis, MinIO
├── docker-compose.app.yml     # 应用服务: Backend, Frontend, Nginx
├── docker-compose.dev.yml     # 本地开发构建覆盖
├── Dockerfile.backend         # 后端镜像构建
├── Dockerfile.frontend        # 前端镜像构建
├── nginx/nginx.conf           # Nginx 反向代理配置
├── build-and-push.sh          # CI/CD 镜像构建脚本
├── settings.example.json      # 配置文件示例
└── settings.schema.json       # 配置文件 JSON Schema
```

## 快速开始

详细部署指南请参阅 [DEPLOY.md](./DEPLOY.md)。

```bash
# 1. 克隆仓库
git clone https://github.com/StreamerHelper/infra.git
cd infra

# 2. 安装依赖 (用于配置工具)
npm install

# 3. 初始化配置
./bin/configure init

# 4. 启动服务
./bin/control infra up    # 启动数据库
./bin/control migrate     # 运行迁移
./bin/control app up      # 启动应用
```

## 命令参考

### 配置管理 (`./bin/configure`)

| 命令 | 说明 |
|------|------|
| `init` | 交互式初始化配置 |
| `edit` | 编辑现有配置 |
| `show` | 显示当前配置 (密码脱敏) |

### 容器管理 (`./bin/control`)

| 命令 | 说明 |
|------|------|
| `infra up` | 启动基础设施 (PostgreSQL, Redis, MinIO) |
| `infra down` | 停止基础设施 |
| `migrate` | 运行数据库迁移 |
| `app up` | 启动应用服务 (Backend, Frontend, Nginx) |
| `app down` | 停止应用服务 |
| `up` | 一键启动全部 (infra + migrate + app) |
| `down` | 停止所有服务 |
| `status` | 查看服务状态 |
| `logs [service]` | 查看日志 |
| `dev up` | 本地构建并启动 |
| `dev build` | 仅构建本地镜像 |

## 访问地址

| 服务 | 地址 | 说明 |
|------|------|------|
| 应用首页 | http://localhost:7080 | Web UI |
| API | http://localhost:7080/api | 后端接口 |
| Bull Board | http://localhost:7080/ui | 队列监控 |
| MinIO Console | http://localhost:7091 | 对象存储管理 |

## 配置文件

配置保存在 `~/.streamer-helper/settings.json`，包含：

- **app**: 应用密钥
- **http**: HTTP/HTTPS 端口
- **database**: PostgreSQL 连接信息
- **redis**: Redis 连接信息
- **s3/minio**: 对象存储配置
- **recorder**: 录制参数
- **poller**: 轮询参数
- **upload**: 上传参数

详见 [settings.example.json](./settings.example.json)。

部署时请注意：
- `http.port` / `httpsPort` / `minio.apiPort` / `minio.consolePort` 只影响宿主机暴露端口。
- Docker 内置 MinIO 默认也统一使用 `minio:7090`；如果你改了 `minio.apiPort`，`s3.endpoint` 默认会跟着改成 `http://minio:<apiPort>`。
- 后端容器内部端口固定为 `7001`，对外访问端口由 Nginx 的 `http.port` 控制。

## 开发者指南

### 本地开发

```bash
# 启动基础设施
./bin/control infra up

# 本地构建并运行
./bin/control dev up
```

### 构建镜像

```bash
# 构建并推送到 Docker Hub
./build-and-push.sh v1.0.0

# 仅构建不推送
./build-and-push.sh v1.0.0 --skip-push
```

### CI/CD

通过 GitHub Actions 自动构建:
- **触发**: 推送 `v*` 标签
- **手动**: 在 Actions 页面手动触发

需要配置 GitHub Secrets:
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

## 故障排除

### 后端启动失败

```bash
# 检查数据库连接
docker exec streamer-postgres pg_isready

# 查看后端日志
./bin/control logs backend
```

### 数据库密码不匹配

PostgreSQL 密码仅在首次初始化时生效。如需重置：

```bash
# 警告: 会清空所有数据
./bin/control down
docker volume rm infra_postgres_data
./bin/control up
```

## License

MIT
