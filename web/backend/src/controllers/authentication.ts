import express from 'express';
import axios, { AxiosError } from 'axios';
import * as oauth from 'oauth4webapi';
import { sciper2sess } from '../session';
import { initEnforcer, getUserPermissions, readSCIPER, setMapAuthorization } from '../authManager';

export const authenticationRouter = express.Router();

initEnforcer().catch((e) => console.error(`Couldn't initialize enforcerer: ${e}`));

// Microsoft Entra ID authentication

// set up authentication
const tenant_id = process.env.MS_ENTRA_TENANT_ID || '';
const client_id = process.env.MS_ENTRA_CLIENT_ID || '';
const redirect_uri = process.env.MS_ENTRA_REDIRECT_URI || '';
const client_secret = process.env.MS_ENTRA_CLIENT_SECRET || '';
if (!(tenant_id && client_id && redirect_uri && client_secret)) {
  throw new Error('required Microsoft Entra ID environment variables are not set');
}

const issuer = new URL(`https://login.microsoftonline.com/${process.env.MS_ENTRA_TENANT_ID}/v2.0`);
const code_challenge_method = 'S256';
const client: oauth.Client = { client_id };
const clientAuth = oauth.ClientSecretPost(client_secret);

let as: oauth.AuthorizationServer;
let code_verifier: string;
let nonce: string;

let authServerPromise: Promise<oauth.AuthorizationServer> | null = null;
let lastFetched: number = 0;
const CACHE_DURATION = 24 * 60 * 60 * 1000; // 24 hours in ms

function getAuthServer(): Promise<oauth.AuthorizationServer> {
  const now = Date.now();

  if (authServerPromise === null || now - lastFetched > CACHE_DURATION) {
    // Renew the setup every 24h: even though the metadata fetched here can be
    // re-used, there could be a key-rotation happening between the first call and
    // the next one. Specifically if the backend server runs for more than 24h.
    lastFetched = now;
    authServerPromise = (async () => {
      const response = await oauth.discoveryRequest(issuer);
      return await oauth.processDiscoveryResponse(issuer, response);
    })();
  }

  return authServerPromise;
}

// authorization endpoint
authenticationRouter.get('/auth-redirect', async (req, res) => {
  try {
    code_verifier = oauth.generateRandomCodeVerifier();
    const code_challenge = await oauth.calculatePKCECodeChallenge(code_verifier);
    const as = await getAuthServer();
    const authorizationUrl = new URL(as.authorization_endpoint);
    authorizationUrl.searchParams.set('client_id', client.client_id);
    authorizationUrl.searchParams.set('redirect_uri', redirect_uri);
    authorizationUrl.searchParams.set('response_type', 'code');
    authorizationUrl.searchParams.set('scope', 'openid email');
    authorizationUrl.searchParams.set('code_challenge', code_challenge);
    authorizationUrl.searchParams.set('code_challenge_method', code_challenge_method);

    // backwards compatibility
    // https://github.com/panva/oauth4webapi/blob/222d1cc7b8e5f81ec1bbaab8ff364209e9dd7d98/examples/oidc.ts#L48
    if (as.code_challenge_methods_supported?.includes(code_challenge_method) !== true) {
      nonce = oauth.generateRandomNonce();
      authorizationUrl.searchParams.set('nonce', nonce);
    }

    // redirect user to Microsoft Entra ID authentication
    res.json({ url: authorizationUrl.href });
  } catch (error) {
    res.status(500).send('Failed to redirect to Microsoft Entra ID for authentication');
    console.error(error);
  }
});

// redirection URI
authenticationRouter.get(redirect_uri.split('/api')[1], async (req, res) => {
  try {
    const params = oauth.validateAuthResponse(
      as,
      { client_id },
      new URL(`${req.protocol}://${req.get('host')}${req.originalUrl}`)
    );
    const response = await oauth.authorizationCodeGrantRequest(
      as,
      { client_id },
      clientAuth,
      params,
      redirect_uri,
      code_verifier
    );
    const result = await oauth.processAuthorizationCodeResponse(as, client, response, {
      expectedNonce: nonce,
      requireIdToken: true,
    });
    const claims = oauth.getValidatedIdTokenClaims(result);
    if (!(claims?.uniqueid && claims?.family_name && claims?.given_name)) {
      throw new Error('Invalid authentication response');
    }
    req.session.userId = parseInt(claims.uniqueid as string, 10);
    req.session.lastName = claims.family_name as string;
    req.session.firstName = claims.given_name as string;

    // log user in into React app
    const sciperSessions = sciper2sess.get(req.session.userId) || new Set<string>();
    sciperSessions.add(req.sessionID);
    sciper2sess.set(req.session.userId, sciperSessions);

    console.log(`user ${req.session.userId} successfully logged in`);

    res.redirect('/logged');
  } catch (error) {
    res.status(500).send('Failed to log in user');
    console.error(error);
  }
});

authenticationRouter.get('/get_dev_login/:userId', (req, res) => {
  if (process.env.REACT_APP_DEV_LOGIN !== 'true') {
    const err = `/get_dev_login can only be called with REACT_APP_DEV_LOGIN===true: ${process.env.REACT_APP_DEV_LOGIN}`;
    console.error(err);
    res.status(500).send(err);
    return;
  }
  if (req.params.userId === undefined) {
    const err = 'no userId given';
    console.error(err);
    res.status(500).send(err);
    return;
  }
  try {
    req.session.userId = readSCIPER(req.params.userId);
    req.session.firstName = 'sciper-#';
    req.session.lastName = req.params.userId;
  } catch (e) {
    const err = `Invalid userId: ${e}`;
    console.error(err);
    res.status(500).send(err);
    return;
  }

  const sciperSessions = sciper2sess.get(req.session.userId) || new Set<string>();
  sciperSessions.add(req.sessionID);
  sciper2sess.set(req.session.userId, sciperSessions);

  res.redirect('/logged');
});

// This endpoint serves to log out from the app by clearing the session.
authenticationRouter.post('/logout', (req, res) => {
  if (req.session.userId === undefined) {
    res.status(400).send('not logged in');
    return;
  }

  const { userId } = req.session;

  req.session.destroy(() => {
    const a = sciper2sess.get(userId as number);
    if (a !== undefined) {
      a.delete(req.sessionID);
      sciper2sess.set(userId as number, a);
    }
    res.redirect('/');
  });
});

// As the user is logged on the app via this express but must also
// be logged into react. This endpoint serves to send to the client (actually to react)
// the information of the current user.
authenticationRouter.get('/personal_info', async (req, res) => {
  if (!req.session.userId) {
    res.status(401).send('Unauthenticated');
    return;
  }
  const userPermissions = await getUserPermissions(req.session.userId);
  res.set('Access-Control-Allow-Origin', '*');
  res.json({
    sciper: req.session.userId,
    lastName: req.session.lastName,
    firstName: req.session.firstName,
    isLoggedIn: true,
    authorization: Object.fromEntries(setMapAuthorization(userPermissions)),
  });
});
