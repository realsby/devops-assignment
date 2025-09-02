FROM node:latest

WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .

# Runs as root, which is the default and we never changed it.
EXPOSE 8080
CMD ["node", "src/index.js"]
