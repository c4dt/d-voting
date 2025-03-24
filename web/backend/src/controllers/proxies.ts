import express, { RequestHandler } from 'express';
import lmdb from 'lmdb';
import { initEnforcer } from '../authManager';

export const proxiesRouter = express.Router();

initEnforcer().catch((e) => console.error(`Couldn't initialize enforcer: ${e}`));

const proxiesDB = lmdb.open<string, string>({ path: `${process.env.DB_PATH}proxies` });

// Middleware checking that the user is an admin
const isAdmin: RequestHandler = async (req, res, next) => {
  if (proxiesDB.getCount({}) === 0) {
    next();
    return;
  }
  if (req.session.userId === undefined) {
    res.status(400).send('Unauthorized - only admins and operators allowed');
    return;
  }
  const nodeAddr = proxiesDB.getKeys().asArray[0];
  const proxy = proxiesDB.get(nodeAddr);
  const adminResp = await fetch(new URL('/evoting/adminlist', proxy).href).then((response) =>
    response.json()
  );
  const admin = adminResp.Admins.includes(req.session.userId.toString());
  if (!admin) {
    res.status(400).send('Unauthorized - only admins and operators allowed');
    return;
  }
  // Calls the next middleware on the chain, since the request is issued by an admin
  next();
};

proxiesRouter.post('', isAdmin, async (req, res) => {
  try {
    const bodydata = req.body;
    proxiesDB.put(bodydata.NodeAddr, bodydata.Proxy);
    res.status(200).send('ok');
  } catch (error: any) {
    res.status(500).send(error.toString());
  }
});

proxiesRouter.put('/:nodeAddr', isAdmin, async (req, res) => {
  let { nodeAddr } = req.params;

  nodeAddr = decodeURIComponent(nodeAddr);

  const proxy = proxiesDB.get(nodeAddr);

  if (proxy === undefined) {
    res.status(404).send(`proxy ${nodeAddr} not found`);
    return;
  }
  try {
    const bodydata = req.body;
    if (bodydata.Proxy === undefined) {
      res.status(400).send(`bad request, proxy ${nodeAddr} is undefined`);
      return;
    }

    const { NewNode } = bodydata;
    if (NewNode !== undefined && NewNode !== nodeAddr) {
      proxiesDB.remove(nodeAddr);
      proxiesDB.put(NewNode, bodydata.Proxy);
    } else {
      proxiesDB.put(nodeAddr, bodydata.Proxy);
    }
    res.status(200).send('ok');
  } catch (error: any) {
    res.status(500).send(error.toString());
  }
});

proxiesRouter.delete('/:nodeAddr', isAdmin, (req, res) => {
  let { nodeAddr } = req.params;

  nodeAddr = decodeURIComponent(nodeAddr);

  const proxy = proxiesDB.get(nodeAddr);

  if (proxy === undefined) {
    res.status(404).send(`proxy ${nodeAddr} not found`);
    return;
  }

  try {
    proxiesDB.remove(nodeAddr);
    res.status(200).send('ok');
  } catch (error: any) {
    res.status(500).send(error.toString());
  }
});

proxiesRouter.get('', (req, res) => {
  const output = new Map<string, string>();
  proxiesDB.getRange({}).forEach((entry) => {
    output.set(entry.key, entry.value);
  });

  res.status(200).json({ Proxies: Object.fromEntries(output) });
});

proxiesRouter.get('/:nodeAddr', (req, res) => {
  const { nodeAddr } = req.params;

  const proxy = proxiesDB.get(decodeURIComponent(nodeAddr));

  if (proxy === undefined) {
    res.status(404).send(`proxy ${nodeAddr} not found`);
    return;
  }

  res.status(200).json({
    NodeAddr: nodeAddr,
    Proxy: proxy,
  });
});
