// Express: POST /bid endpoint + in-memory bid store per pool/block
import * as dotenv from 'dotenv';
import express from 'express';
dotenv.config();

const app = express();
app.use(express.json());
const PORT = process.env.PORT ?? 3001;

app.listen(PORT, () => console.log(`Searcher RPC listening on ${PORT}`));