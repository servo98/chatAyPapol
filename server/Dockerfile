# Imagen del backend de ChatPapol (Bun + Hono + SQLite).
# Se publica automáticamente en ghcr.io/servo98/chatpapol-server al tocar server/**
FROM oven/bun:1-slim
WORKDIR /app

COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

COPY src ./src

ENV PORT=3210
EXPOSE 3210
# SQLite + uploads/stickers/sonidos/releases viven aquí: móntalo como volumen
VOLUME /app/data

CMD ["bun", "src/index.ts"]
