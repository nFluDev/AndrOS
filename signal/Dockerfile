FROM node:22-alpine
WORKDIR /app
# Bagimliliklar once: kaynak degisince npm katmani yeniden kurulmasin.
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
ENV PORT=3000 STUN_PORT=3478
EXPOSE 3000
EXPOSE 3478/udp
CMD ["node", "server.js"]
