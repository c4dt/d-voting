// information accessed through the middleware
import { UserRole } from '../../types/userRole';

export const ENDPOINT_GET_TEQ_KEY = '/api/get_teq_key';
export const ENDPOINT_DEV_LOGIN = '/api/get_dev_login';
export const ENDPOINT_PERSONAL_INFO = '/api/personal_info';
export const ENDPOINT_LOGOUT = '/api/logout';
export const ENDPOINT_USER_RIGHTS = '/api/user_rights';
export const ENDPOINT_ADD_ROLE = '/api/add_role';
export const ENDPOINT_REMOVE_ROLE = '/api/remove_role';
export const ENDPOINT_ADD_ADMIN = '/api/evoting/auth/addadmin';
export const ENDPOINT_REMOVE_ADMIN = '/api/evoting/auth/removeadmin';
export const checkTransaction = (token: string) => `/api/evoting/transactions/${token}`;

export const newForm = '/api/evoting/forms';
export const editForm = (FormID: string) => `/api/evoting/forms/${FormID}`;
export const addRoleToForm = (formID: string, role: UserRole) =>
  `/api/evoting/auth/forms/${formID}/add${role}`;
export const removeRoleToForm = (formID: string, role: UserRole) =>
  `/api/evoting/auth/forms/${formID}/remove${role}`;
export const newFormVote = (FormID: string) => `/api/evoting/forms/${FormID}/vote`;
export const editShuffle = (FormID: string) => `/api/evoting/services/shuffle/${FormID}`;
export const addFormAuthorization = `/api/evoting/authorizations`;
// setup and decrypt
export const editDKGActors = (FormID: string) => `/api/evoting/services/dkg/actors/${FormID}`;
// initialize the nodes
export const dkgActors = `/api/evoting/services/dkg/actors`;

export const getDKGActors = (Proxy: string, FormID: string) =>
  encodeURI(`${Proxy}/evoting/services/dkg/actors/${FormID}`);

export const newProxyAddress = '/api/proxies/';
export const editProxyAddress = (NodeAddr: string) =>
  `/api/proxies/${encodeURIComponent(NodeAddr)}`;
export const getProxyAddress = (NodeAddr: string) => `/api/proxies/${encodeURIComponent(NodeAddr)}`;
export const getProxiesAddresses = '/api/proxies';

// public information can be directly fetched from dela nodes
export const form = (proxy: string, FormID: string) =>
  new URL(`/evoting/forms/${FormID}`, proxy).href;
export const forms = (proxy: string) => new URL('/evoting/forms', proxy).href;
export const adminlist = (proxy: string) => new URL('/evoting/adminlist', proxy).href;

// get the default proxy address
export const getProxyConfig = '/api/config/proxy';

// To remove
export const ENDPOINT_EVOTING_RESULT = '/api/evoting/result';
