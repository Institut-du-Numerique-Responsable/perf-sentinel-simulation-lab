# nest-svc multistage Dockerfile.
#
#   1. node:24-bookworm-slim builder: npm ci + prisma generate + nest build.
#   2. gcr.io/distroless/nodejs24-debian12:nonroot runtime.
#      UID 65532, no shell.
#
# Build with:  docker build -t nest-svc:s1 services/nest-svc

# ---- builder ----
FROM node:26-bookworm-slim AS builder
WORKDIR /build

COPY package.json package-lock.json* ./
RUN npm install --ignore-scripts

COPY prisma ./prisma
RUN npx prisma generate

COPY tsconfig.json nest-cli.json ./
COPY src ./src
RUN npx nest build

# Prune devDependencies for the runtime image.
RUN npm prune --production

# ---- runtime ----
FROM gcr.io/distroless/nodejs24-debian12:nonroot

WORKDIR /app
COPY --from=builder /build/node_modules /app/node_modules
COPY --from=builder /build/dist /app/dist
COPY --from=builder /build/prisma /app/prisma

# Prisma client needs the generated engine at runtime.
COPY --from=builder /build/node_modules/.prisma /app/node_modules/.prisma

EXPOSE 8090
USER 65532:65532

CMD ["dist/main.js"]
