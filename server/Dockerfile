# Race server image (used by Railway). Raw TCP + newline-delimited JSON on $PORT.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npx tsc -p . && npm prune --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production HOST=:: PORT=7777
RUN apk add --no-cache su-exec
COPY --from=build /app/package.json ./
COPY --from=build /app/dist ./dist
EXPOSE 7777
# Volumes mount owned by root: give the race records' folder (RACE_LOG_DIR,
# Railway: /data/races) and the personal bests' folder (PB_FILE's, /data) to
# the node user, then run the server as node.
CMD ["sh", "-c", "if [ -n \"$RACE_LOG_DIR\" ]; then mkdir -p \"$RACE_LOG_DIR\" && chown -R node:node \"$RACE_LOG_DIR\"; fi; if [ -n \"$PB_FILE\" ]; then d=$(dirname \"$PB_FILE\"); mkdir -p \"$d\" && chown node:node \"$d\" && { [ ! -e \"$PB_FILE\" ] || chown node:node \"$PB_FILE\"; }; fi; exec su-exec node node dist/src/index.js"]
