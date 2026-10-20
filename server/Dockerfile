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
COPY --from=build /app/package.json ./
COPY --from=build /app/dist ./dist
EXPOSE 7777
USER node
CMD ["node", "dist/src/index.js"]
