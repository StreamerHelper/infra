# StreamerHelper 部署指南

本文档面向新用户，详细介绍如何配置、部署和更新 StreamerHelper。

## 目录

- [环境要求](#环境要求)
- [首次部署](#首次部署)
- [配置说明](#配置说明)
- [日常操作](#日常操作)
- [版本更新](#版本更新)
- [数据备份](#数据备份)
- [常见问题](#常见问题)

---

## 环境要求

- **Docker** 20.10+
- **Docker Compose** v2+
- **jq** (JSON 处理工具)
- **Node.js** 18+ (仅配置工具需要)
- 至少 **4GB 可用内存**

### 安装依赖

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y docker.io docker-compose-v2 jq nodejs npm

# macOS (使用 Homebrew)
brew install docker jq node

# 启动 Docker 服务 (Linux)
sudo systemctl enable docker
sudo systemctl start docker
```

---

## 首次部署

### 第一步：获取部署文件

```bash
git clone https://github.com/StreamerHelper/infra.git
cd infra
npm install
```

### 第二步：初始化配置

运行交互式配置工具：

```bash
./bin/configure init
```

按提示输入：
- **HTTP 端口** (默认 7080)
- **数据库密码** (留空自动生成)
- **MinIO 密钥** (留空自动生成)

配置会保存到 `~/.streamer-helper/settings.json`。

### 第三步：启动基础设施

```bash
./bin/control infra up
```

等待所有服务健康检查通过 (约 30 秒)：
- PostgreSQL
- Redis
- MinIO

### 第四步：安装明确版本并启动应用

```bash
RELEASE_VERSION=v1.2.3 # 替换为要安装的已发布版本
./bin/control update app "$RELEASE_VERSION"
```

该命令会拉取同版本的全部应用镜像、创建数据库表、启动应用，并在健康检查通过后写入 release pin。

### 第五步：验证访问

等待 Backend 和 Frontend 健康检查通过后，即可访问：

| 服务 | 地址 |
|------|------|
| 应用首页 | http://localhost:7080 |
| MinIO 控制台 | http://localhost:7091 |

### 首次一键部署 (可选)

配置完成后，也可以让一条命令完成基础设施与应用的首次部署：

```bash
RELEASE_VERSION=v1.2.3 # 替换为要安装的已发布版本
./bin/control update all "$RELEASE_VERSION"
```

首次成功后，普通的 `./bin/control up` 会使用已写入的 release pin；没有有效 pin 时它会明确失败，不会回退到 `latest`。

---

## 配置说明

### 配置文件位置

```
~/.streamer-helper/
├── settings.json      # 主配置文件
├── .docker-env        # Docker 环境变量 (自动生成)
└── release-version    # 当前应用发布版本 (非密钥，首次安装或更新成功后原子写入)
```

### 查看当前配置

```bash
./bin/configure show
```

敏感信息 (密码、密钥) 会脱敏显示。
控制或配置工具加载旧配置时，会先验证 JSON，再原子删除已废弃的 `platforms.douyin.cookie`。升级保留原文件权限、`userAgent` 和其它字段，日志不会输出旧 Cookie 值；JSON 无效时拒绝改写。

### 修改配置

```bash
./bin/configure edit
```

选择要修改的配置项，按提示操作。

**修改配置后需要重启服务：**

```bash
./bin/control app down
./bin/control app up
```

### 配置项说明

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `http.port` | HTTP 端口 | 7080 |
| `http.httpsPort` | HTTPS 端口 | 7443 |
| `database.password` | 数据库密码 | 自动生成 |
| `s3.accessKey` | MinIO 访问密钥 | minioadmin |
| `s3.secretKey` | MinIO 私密密钥 | 自动生成 |
| `minio.apiPort` | MinIO API 端口 | 7090 |
| `minio.consolePort` | MinIO 控制台端口 | 7091 |
| `recorder.maxRecordingTime` | 最大录制时长 (秒) | 86400 |
| `poller.checkInterval` | 轮询间隔 (秒) | 60 |

注意：
- `http.port`、`http.httpsPort`、`minio.apiPort`、`minio.consolePort` 是宿主机暴露端口。
- Docker 内置 MinIO 默认也统一使用 `minio:7090`。
- 因此如果你改了 MinIO 的 API 端口，`s3.endpoint` 和 `s3.publicEndpoint` 默认都会跟着改。
- 后端容器内部监听端口固定为 `7001`。如需更改对外访问端口，请修改 `http.port`，不要修改 `app.port`。

---

## 日常操作

### 查看服务状态

```bash
./bin/control status
```

输出示例：
```
NAMES               STATUS                  PORTS
streamer-nginx      Up 2 hours              0.0.0.0:7080->80/tcp
streamer-frontend   Up 2 hours (healthy)    3000/tcp
streamer-backend    Up 2 hours (healthy)    7001/tcp
streamer-browser    Up 2 hours (healthy)    9222/tcp
streamer-douyin-resolver Up 2 hours (healthy) 7100/tcp
streamer-postgres   Up 2 hours (healthy)    5432/tcp
streamer-redis      Up 2 hours (healthy)    6379/tcp
streamer-minio      Up 2 hours (healthy)    0.0.0.0:7090-7091->7090-7091/tcp
```

### 查看日志

```bash
# 所有服务
./bin/control logs

# 指定服务
./bin/control logs backend
./bin/control logs frontend
```

### 停止服务

```bash
# 停止应用 (保留数据库)
./bin/control app down

# 停止全部
./bin/control down
```

### 重启服务

```bash
# 重启全部
./bin/control down
./bin/control up

# 只重启应用
./bin/control app down
./bin/control app up
```

---

## 版本更新

### 方法一：使用 `update` 命令 (推荐)

```bash
# 使用同一版本更新全部应用镜像
./bin/control update app v1.2.3

# 更新 PostgreSQL、Redis、MinIO
./bin/control update infra

# 全量更新并锁定应用版本
./bin/control update all v1.2.3
```

应用更新必须提供 `latest` 以外的明确版本；发布流程拒绝覆盖已经存在的版本标签。
生产应用镜像默认位于 `ghcr.io/streamerhelper`。通过 CI tag 发布时，infra、web-server 和 web 三个仓库必须先创建同名 tag；手动触发工作流时则明确提供两个源码仓库的 tag 或 commit。工作流使用 `github.actor` 与当前任务的 `GITHUB_TOKEN` 登录 GHCR，工作流摘要会记录最终构建的三个源码 SHA。

`update app` 会自动完成：
- 拉取 backend / frontend / browser / douyin-resolver 镜像
- 在当前应用保持在线时，用目标 backend 镜像执行数据库迁移
- 迁移成功后重建应用容器
- 等待 Backend 和 Frontend 健康；Browser 或 Douyin Resolver 异常时报告降级但不阻断其它平台
- 仅在必要健康检查通过后原子更新 `~/.streamer-helper/release-version`

后续普通的 `app down`、`app up`、`status` 和 `logs` 都会读取该 release pin。没有 pin 或 pin 损坏时，生产模式启动会明确失败，不会退回到 `latest`；Compose 应用文件本身也要求四个应用版本变量非空。请通过 `bin/control` 执行生产启停，其中停止命令不依赖 pin。更新失败时会保留更新前的运行状态：原来运行则保持或恢复原 pin 对应的应用，原来停止则清理可能创建的候选容器并保持停止。`update all` 会记住主动停止应用之前的状态并传递给同一恢复路径。

如果镜像已经由其它机器导入服务器，可以显式跳过 registry pull：

```bash
./bin/control update app v1.2.3 --preloaded
```

该模式会先验证以下四个精确标签均已存在于本机：

```text
ghcr.io/streamerhelper/streamerhelper-backend:v1.2.3
ghcr.io/streamerhelper/streamerhelper-frontend:v1.2.3
ghcr.io/streamerhelper/streamerhelper-browser:v1.2.3
ghcr.io/streamerhelper/streamerhelper-douyin-resolver:v1.2.3
```

它只跳过拉取步骤，数据库迁移、容器重建、健康检查、release pin 和失败回滚与默认更新路径完全一致。任一镜像缺失时会在迁移和重建前退出。

`update infra` 会自动完成：
- 拉取 PostgreSQL / Redis / MinIO 镜像
- 重建基础设施容器
- 等待健康检查通过
- 重新同步 PostgreSQL 密码并检查 MinIO bucket

### 方法二：手工拉取镜像

```bash
VERSION=v1.2.3
docker pull "ghcr.io/streamerhelper/streamerhelper-backend:${VERSION}"
docker pull "ghcr.io/streamerhelper/streamerhelper-frontend:${VERSION}"
docker pull "ghcr.io/streamerhelper/streamerhelper-browser:${VERSION}"
docker pull "ghcr.io/streamerhelper/streamerhelper-douyin-resolver:${VERSION}"
./bin/control update app "$VERSION" --preloaded
```

### 方法三：构建并发布生产镜像

发布者需要先登录 GHCR：

```bash
docker login ghcr.io
./build-and-push.sh v1.2.3
```

脚本会在构建前验证本地 credential，并对四个目标标签执行 fail-closed 的不可变性探测。缺少登录、权限不足、网络异常或 registry 无法明确证明标签不存在时都会停止，不会开始发布；成功后生成 `linux/amd64` 与 `linux/arm64` 双架构镜像。

### 方法四：本地开发构建

```bash
# 1. 更新代码
cd ../web-server && git pull
cd ../web && git pull
cd ../infra

# 2. 构建并启动
./bin/control dev up
```

### 更新部署工具

```bash
cd infra
git pull
npm install
```

---

## 数据备份

### 备份数据库

```bash
# 导出数据库
docker exec streamer-postgres pg_dump -U postgres streamerhelper > backup.sql

# 恢复数据库
cat backup.sql | docker exec -i streamer-postgres psql -U postgres streamerhelper
```

### 备份 MinIO 数据

MinIO 数据存储在 Docker Volume 中：

```bash
# 查看 Volume
docker volume inspect infra_minio_data

# 备份 (需要停止服务)
docker run --rm -v infra_minio_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/minio-backup.tar.gz /data
```

### 备份配置

```bash
cp ~/.streamer-helper/settings.json ~/settings-backup.json
```

---

## 常见问题

### Q: 数据库密码错误

PostgreSQL 密码仅在首次启动时设置。如果修改了配置文件中的密码但数据库已初始化：

**方法一：手动同步密码**
```bash
docker exec streamer-postgres psql -U postgres -c "ALTER USER postgres WITH PASSWORD '新密码';"
```

**方法二：重置数据库** (会丢失所有数据)
```bash
./bin/control down
docker volume rm infra_postgres_data
./bin/control up
```

### Q: 端口被占用

修改配置中的端口：
```bash
./bin/configure edit
# 选择 HTTP Settings，修改端口
```

或者停止占用端口的服务：
```bash
# 查看占用端口的进程
lsof -i :7080
```

### Q: MinIO 控制台无法访问

确认 MinIO 服务正在运行：
```bash
./bin/control status | grep minio
```

检查端口映射是否正确 (应显示 `0.0.0.0:7091->7091/tcp`)。

### Q: 后端启动失败

1. 检查日志：
   ```bash
   ./bin/control logs backend
   ```

2. 确认数据库已启动：
   ```bash
   docker exec streamer-postgres pg_isready
   ```

3. 确认配置文件存在：
   ```bash
   ls -la ~/.streamer-helper/settings.json
   ```

### Q: 如何完全重置

```bash
# 停止并删除所有容器和数据
./bin/control down
docker volume rm infra_postgres_data infra_redis_data infra_minio_data

# 删除配置
rm -rf ~/.streamer-helper

# 重新部署
./bin/configure init
RELEASE_VERSION=v1.2.3 # 替换为要安装的已发布版本
./bin/control update all "$RELEASE_VERSION"
```

---

## 联系支持

- GitHub Issues: https://github.com/StreamerHelper/infra/issues
- 文档: https://github.com/StreamerHelper/infra
