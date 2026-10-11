FROM alpine:3.20

RUN apk add --no-cache \
    lua5.4 \
    curl \
    bash \
    dcron \
    flock \
    make \
    tzdata \
    tini

# Provide a plain `lua` command so the Makefile and tests work unchanged.
RUN ln -sf /usr/bin/lua5.4 /usr/local/bin/lua

WORKDIR /app

# Application code and examples. Secrets and local config are mounted at runtime.
COPY bin/ ./bin/
COPY src/ ./src/
COPY schedule.csv ./
COPY config.example.toml ./
COPY .env.example ./
COPY Makefile ./
COPY tests/ ./tests/

RUN mkdir -p var && chmod 700 var

# The entrypoint runs one-off bot commands directly and uses tini only when
# starting the cron daemon, because dcron calls setpgid and cannot run as PID 1.
ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]
