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
- **HTTP 端口** (默认 80)
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

### 第四步：运行数据库迁移

```bash
./bin/control migrate
```

首次运行会创建所有数据库表。

### 第五步：启动应用

```bash
./bin/control app up
```

等待后端健康检查通过后，即可访问：

| 服务 | 地址 |
|------|------|
| 应用首页 | http://localhost |
| MinIO 控制台 | http://localhost:9001 |

### 一键启动 (可选)

上述步骤也可以用一条命令完成：

```bash
./bin/control up
```

---

## 配置说明

### 配置文件位置

```
~/.streamer-helper/
├── settings.json      # 主配置文件
└── .docker-env        # Docker 环境变量 (自动生成)
```

### 查看当前配置

```bash
./bin/configure show
```

敏感信息 (密码、密钥) 会脱敏显示。

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
| `http.port` | HTTP 端口 | 80 |
| `http.httpsPort` | HTTPS 端口 | 443 |
| `database.password` | 数据库密码 | 自动生成 |
| `s3.accessKey` | MinIO 访问密钥 | minioadmin |
| `s3.secretKey` | MinIO 私密密钥 | 自动生成 |
| `minio.consolePort` | MinIO 控制台端口 | 9001 |
| `recorder.maxRecordingTime` | 最大录制时长 (秒) | 86400 |
| `poller.checkInterval` | 轮询间隔 (秒) | 60 |

---

## 日常操作

### 查看服务状态

```bash
./bin/control status
```

输出示例：
```
NAMES               STATUS                  PORTS
streamer-nginx      Up 2 hours              0.0.0.0:80->80/tcp
streamer-frontend   Up 2 hours (healthy)    3000/tcp
streamer-backend    Up 2 hours (healthy)    7001/tcp
streamer-postgres   Up 2 hours (healthy)    5432/tcp
streamer-redis      Up 2 hours (healthy)    6379/tcp
streamer-minio      Up 2 hours (healthy)    0.0.0.0:9000-9001->9000-9001/tcp
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

### 方法一：使用预构建镜像 (推荐)

```bash
# 1. 拉取最新镜像
docker pull umuoy1/streamerhelper-backend:latest
docker pull umuoy1/streamerhelper-frontend:latest

# 2. 重启应用
./bin/control app down
./bin/control migrate      # 运行新的数据库迁移
./bin/control app up
```

### 方法二：本地构建

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
lsof -i :80
```

### Q: MinIO 控制台无法访问

确认 MinIO 服务正在运行：
```bash
./bin/control status | grep minio
```

检查端口映射是否正确 (应显示 `0.0.0.0:9001->9001/tcp`)。

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
./bin/control up
```

---

## 联系支持

- GitHub Issues: https://github.com/StreamerHelper/infra/issues
- 文档: https://github.com/StreamerHelper/infra
