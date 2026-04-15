import { startServer } from "./server.ts";

const port = Number(process.env.PORT ?? 8787);
const dbPath = process.env.DB_PATH ?? "coloring-book.db";
startServer(port, dbPath);
