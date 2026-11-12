# nest-svc multistage Dockerfile.
#
#   1. node:26-trixie-slim builder: npm install + prisma generate + nest build.
#   2. gcr.io/distroless/nodejs26-debian13:nonroot runtime.
#      UID 65532, no shell.
#
# Build with:  docker build -t nest-svc:s1 services/nest-svc

# ---- builder ----
FROM node:26-trixie-slim AS builder
WORKDIR /build

COPY package.json package-lock.json* ./
RUN npm install --ignore-scripts

# Prisma 7 generates a TypeScript client into src/generated, compiled by nest build.
COPY prisma ./prisma
RUN npx prisma generate

COPY tsconfig.json nest-cli.json ./
COPY src ./src
RUN npx nest build

# Prune devDependencies for the runtime image.
RUN npm prune --omit=dev

# ---- runtime ----
FROM gcr.io/distroless/nodejs26-debian13:nonroot

WORKDIR /app
COPY --from=builder /build/node_modules /app/node_modules
COPY --from=builder /build/dist /app/dist

EXPOSE 8090
USER 65532:65532

CMD ["dist/main.js"]
