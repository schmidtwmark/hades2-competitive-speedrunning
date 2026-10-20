// Raw TCP transport: newline-delimited JSON, one RaceServer connection per socket.

import net from "node:net";
import type { RaceServer } from "./race-server.js";

const MAX_LINE = 16 * 1024;

export function listen(server: RaceServer, port: number, host: string, log: (line: string) => void): Promise<net.Server> {
  const tcp = net.createServer((socket) => {
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 10_000);
    socket.setEncoding("utf8");
    const peer = `${socket.remoteAddress}:${socket.remotePort}`;
    const conn = server.connect((msg) => {
      if (!socket.destroyed) socket.write(JSON.stringify(msg) + "\n");
    });
    log(`connect ${peer} -> ${conn.session.id}`);
    let buf = "";
    socket.on("data", (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line.length === 0) continue;
        let value: unknown;
        try {
          value = JSON.parse(line);
        } catch {
          socket.write(JSON.stringify({ type: "error", code: "bad_json", message: "invalid JSON line" }) + "\n");
          continue;
        }
        conn.receive(value);
      }
      if (buf.length > MAX_LINE) {
        log(`line too long from ${peer}, closing`);
        socket.destroy();
      }
    });
    socket.on("close", () => {
      log(`close ${peer} (${conn.session.id})`);
      conn.close();
    });
    socket.on("error", (err) => log(`socket error ${peer}: ${err.message}`));
  });
  return new Promise((resolve, reject) => {
    tcp.once("error", reject);
    tcp.listen(port, host, () => {
      tcp.off("error", reject);
      resolve(tcp);
    });
  });
}
