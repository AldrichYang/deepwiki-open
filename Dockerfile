# syntax=docker/dockerfile:1-labs

# Build argument for custom certificates directory
ARG CUSTOM_CERT_DIR="certs"
# Build argument for PyPI mirror (默认使用清华镜像源，适合国内用户)
ARG USE_PYPI_MIRROR="true"

FROM node:20-alpine3.22 AS node_base

FROM node_base AS node_deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps

FROM node_base AS node_builder
WORKDIR /app
COPY --from=node_deps /app/node_modules ./node_modules
# Copy only necessary files for Next.js build
COPY package.json package-lock.json next.config.ts tsconfig.json tailwind.config.js postcss.config.mjs ./
COPY src/ ./src/
COPY public/ ./public/
# Increase Node.js memory limit for build and disable telemetry
ENV NODE_OPTIONS="--max-old-space-size=4096"
ENV NEXT_TELEMETRY_DISABLED=1
RUN NODE_ENV=production npm run build

FROM python:3.11-slim AS py_deps
# 接收构建参数
ARG USE_PYPI_MIRROR
# 添加编译工具和 SSL 相关依赖（用于从源码编译 Python 包和网络连接）
# 包括 Rust 工具链（pydantic-core 等包可能需要）
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3-dev \
    libssl-dev \
    libffi-dev \
    ca-certificates \
    curl \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*
# 更新 CA 证书
RUN update-ca-certificates
WORKDIR /api
COPY api/pyproject.toml .
COPY api/poetry.lock .
# 配置 pip 使用更可靠的设置并升级
# 使用 --root-user-action=ignore 抑制 root 用户警告
# 默认使用清华镜像源（适合国内用户）
# 在 pip install 命令中直接使用镜像源参数，避免从官方源下载超时
RUN if [ "$USE_PYPI_MIRROR" = "true" ]; then \
        PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple" && \
        PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn" && \
        echo "使用清华 PyPI 镜像源" && \
        python -m pip install --upgrade pip setuptools wheel --no-cache-dir --root-user-action=ignore \
            --index-url ${PIP_INDEX_URL} --trusted-host ${PIP_TRUSTED_HOST} && \
        python -m pip install poetry==2.0.1 --no-cache-dir --root-user-action=ignore \
            --index-url ${PIP_INDEX_URL} --trusted-host ${PIP_TRUSTED_HOST} && \
        pip config set global.index-url ${PIP_INDEX_URL} && \
        pip config set global.trusted-host ${PIP_TRUSTED_HOST}; \
    else \
        echo "使用官方 PyPI 源" && \
        python -m pip install --upgrade pip setuptools wheel --no-cache-dir --root-user-action=ignore && \
        python -m pip install poetry==2.0.1 --no-cache-dir --root-user-action=ignore; \
    fi && \
    pip config set global.timeout 600 && \
    pip config set global.retries 15 && \
    pip config set global.default-timeout 600 && \
    poetry config virtualenvs.create true --local && \
    poetry config virtualenvs.in-project true --local && \
    poetry config virtualenvs.options.always-copy --local true && \
    poetry config installer.max-workers 2 && \
    poetry config installer.parallel false && \
    # 根据构建参数配置 Poetry 镜像源（默认使用）
    if [ "$USE_PYPI_MIRROR" = "true" ]; then \
        poetry source add --priority=primary tsinghua https://pypi.tuna.tsinghua.edu.cn/simple || true && \
        echo "Poetry 已配置使用清华镜像源"; \
    fi && \
    # 如果 pyproject.toml 和 poetry.lock 不同步，先更新 lock 文件
    # 运行 poetry lock 来同步 lock 文件（如果已同步则快速返回）
    poetry lock --no-interaction && \
    POETRY_MAX_WORKERS=2 poetry install --no-interaction --no-ansi --only main --no-root && \
    poetry cache clear --all .

# Use Python 3.11 as final image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install Node.js and npm
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    git \
    ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Update certificates if custom ones were provided and copied successfully
RUN if [ -n "${CUSTOM_CERT_DIR}" ]; then \
        mkdir -p /usr/local/share/ca-certificates && \
        if [ -d "${CUSTOM_CERT_DIR}" ]; then \
            cp -r ${CUSTOM_CERT_DIR}/* /usr/local/share/ca-certificates/ 2>/dev/null || true; \
            update-ca-certificates; \
            echo "Custom certificates installed successfully."; \
        else \
            echo "Warning: ${CUSTOM_CERT_DIR} not found. Skipping certificate installation."; \
        fi \
    fi

ENV PATH="/opt/venv/bin:$PATH"

# Copy Python dependencies
COPY --from=py_deps /api/.venv /opt/venv
COPY api/ ./api/

# Copy Node app
COPY --from=node_builder /app/public ./public
COPY --from=node_builder /app/.next/standalone ./
COPY --from=node_builder /app/.next/static ./.next/static

# Expose the port the app runs on
EXPOSE ${PORT:-8001} 3000

# Create a script to run both backend and frontend
RUN echo '#!/bin/bash\n\
# Load environment variables from .env file if it exists\n\
if [ -f .env ]; then\n\
  export $(grep -v "^#" .env | xargs -r)\n\
fi\n\
\n\
# Check for required environment variables\n\
if [ -z "$OPENAI_API_KEY" ] || [ -z "$GOOGLE_API_KEY" ]; then\n\
  echo "Warning: OPENAI_API_KEY and/or GOOGLE_API_KEY environment variables are not set."\n\
  echo "These are required for DeepWiki to function properly."\n\
  echo "You can provide them via a mounted .env file or as environment variables when running the container."\n\
fi\n\
\n\
# Start the API server in the background with the configured port\n\
python -m api.main --port ${PORT:-8001} &\n\
PORT=3000 HOSTNAME=0.0.0.0 node server.js &\n\
wait -n\n\
exit $?' > /app/start.sh && chmod +x /app/start.sh

# Set environment variables
ENV PORT=8001
ENV NODE_ENV=production
ENV SERVER_BASE_URL=http://localhost:${PORT:-8001}

# Create empty .env file (will be overridden if one exists at runtime)
RUN touch .env

# Command to run the application
CMD ["/app/start.sh"]
