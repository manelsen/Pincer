FROM node:22-alpine AS builder

WORKDIR /app

# Install dependencies first for caching
COPY package*.json ./
RUN npm install

# Copy source and build
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# Production image
FROM node:22-alpine

WORKDIR /app

# We only need the compiled files and production deps
COPY package*.json ./
RUN npm install --omit=dev

COPY --from=builder /app/dist ./dist

# Run as non-root user for security (defense in depth)
USER node

# Default to our sidecar, but allow overriding to run npx
CMD ["node", "dist/index.js"]
