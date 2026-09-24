# Same image locally and on Lambda. The Lambda Web Adapter is a Lambda
# extension: outside Lambda (docker run / compose) nothing invokes it, so
# it's inert and the container just runs the normal HTTP server.
FROM node:24-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

COPY . .

USER node

ENV PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz

EXPOSE 8080
CMD ["node", "src/index.js"]
