# syntax=docker/dockerfile:1
#
# Runtime image for the production planner.
#
# Two things are prepared ON THE HOST before this image is built, because this
# host's container write path costs 600-900 ms per small file (measured in
# sandbox/docker-compose.erpnext-ai-fix.yml) and both toolchains write tens of
# thousands of them. In-image `npm ci` ran >15 minutes without finishing:
#
#     npm run build:frontend        # -> frontend/build/
#     npm run deps:server           # -> runtime-deps/node_modules (pure JS only)
#
# `runtime-deps/node_modules` therefore ships pre-installed and is copied, not
# installed. server.js only requires express, cors, axios and dotenv — all pure
# JS — so there is nothing native to build (it never imports sqlite3, which is
# why the runtime deps live in their own manifest instead of the app manifest).
#
# The result is still one image, one process, one origin: server.js serves both
# /api and the compiled SPA (see the STATIC FRONTEND block at its bottom).

FROM node:20-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
COPY runtime-deps/node_modules ./node_modules

COPY server.js ./
COPY frontend/build ./frontend/build
RUN test -f frontend/build/index.html || (echo "frontend/build/index.html missing - run: npm run build:frontend" && exit 1)
RUN node -e "require('express');require('axios');require('cors');require('dotenv')" || (echo "node_modules missing runtime deps - run: npm run deps:server" && exit 1)
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
