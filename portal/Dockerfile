# Same image locally and on Lambda. The Lambda Web Adapter is a Lambda
# extension: outside Lambda (docker run / compose) nothing invokes it, so
# it's inert and the container just runs the normal HTTP server.
FROM node:24-alpine

WORKDIR /app

COPY package.json package-lock.json ./
# npm ships inside this base image with its own vulnerable transitive
# deps (brace-expansion, ip-address, tar — flagged by trivy). We only
# need npm to install our deps at build time; the app never calls it at
# runtime (CMD is `node`, not `npm start`), so drop it once it's done.
RUN npm ci --omit=dev \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

COPY . .

USER node

ENV PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz

EXPOSE 8080
CMD ["node", "src/index.js"]
