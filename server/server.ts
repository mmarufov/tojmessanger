import { startRelay } from "./relay";

startRelay(Number(process.env.PORT ?? 8787));
