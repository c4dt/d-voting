import React, { FC, useContext, useEffect, useMemo, useState } from 'react';
import { AuthContext, FlashContext, FlashLevel, ProxyContext } from 'index';
import Loading from 'pages/Loading';
import { useTranslation } from 'react-i18next';
import { fetchCall } from 'components/utils/fetchCall';
import AdminTable from './AdminTable';
import DKGTable from './DKGTable';
import * as endpoints from 'components/utils/Endpoints';
import { UserRole } from '../../types/userRole';

const Admin: FC = () => {
  const { t } = useTranslation();
  const authCtx = useContext(AuthContext);
  const fctx = useContext(FlashContext);
  const proxyCtx = useContext(ProxyContext);
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [nodeProxyLoading, setNodeProxyLoading] = useState(true);
  const [nodeProxyObject, setNodeProxyObject] = useState({ Proxies: [] });
  const [nodeProxyError, setNodeProxyError] = useState(null);

  const abortController = useMemo(() => new AbortController(), []);

  useEffect(() => {
    if (authCtx.isAdmin) {
      fetchCall(
        endpoints.getProxiesAddresses,
        {
          method: 'GET',
          signal: abortController.signal,
        },
        setNodeProxyObject,
        setNodeProxyLoading
      ).catch((e) => {
        setNodeProxyError(e);
      });
    }
  }, [abortController.signal, authCtx.isAdmin]);

  const [nodeProxyAddresses, setNodeProxyAddresses] = useState<Map<string, string>>(null);

  useEffect(() => {
    if (nodeProxyError !== null) {
      fctx.addMessage(t('errorRetrievingProxy') + nodeProxyError.message, FlashLevel.Error);
      setNodeProxyError(null);
      setNodeProxyLoading(false);
    }
  }, [fctx, nodeProxyError, t]);

  useEffect(() => {
    if (nodeProxyObject !== null) {
      const newNodeProxyAddresses = new Map();

      const proxies = nodeProxyObject.Proxies;

      for (const [node, proxy] of Object.entries(proxies)) {
        newNodeProxyAddresses.set(node, proxy);
      }

      setNodeProxyAddresses(newNodeProxyAddresses);
      setNodeProxyLoading(false);
    }

    return () => {
      abortController.abort();
    };
  }, [abortController, t, nodeProxyObject, nodeProxyError]);

  useEffect(() => {
    const fetchAdminsAndOps = async () => {
      const adminReq = fetch(endpoints.adminlist(proxyCtx.getProxy()));
      const operatorReq = fetch(endpoints.operatorlist(proxyCtx.getProxy()));
      try {
        const adminResp = await adminReq;
        const operatorResp = await operatorReq;
        setLoading(false);
        let roleList = [];
        if (adminResp.status === 200) {
          const result = await adminResp.json();
          roleList = result.Admins.map((x) => ({
            sciper: x,
            role: UserRole.Admin,
          }));
        }
        if (operatorResp.status === 200) {
          const result = await operatorResp.json();
          const operators = result.Operators.map((x) => ({
            sciper: x,
            role: UserRole.Operator,
          }));
          roleList = [...roleList, ...operators];
        }
        roleList.sort((x, y) => parseInt(x.sciper) - parseInt(y.sciper));
        setUsers(roleList);
      } catch (error) {
        setUsers([]);
        fctx.addMessage(t(`errorFetchingUsers: ${error.message}`), FlashLevel.Error);
      }
    };
    fetchAdminsAndOps();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return !loading && !nodeProxyLoading ? (
    <div className="w-[60rem] font-sans px-4 py-4">
      <div className="flex items-center justify-between mb-4 pt-8">
        <div className="flex-1 min-w-0">
          <h2 className="text-2xl font-bold leading-7 text-gray-900 sm:text-3xl sm:truncate">
            {t('admin')}
          </h2>
        </div>
      </div>

      <AdminTable users={users} setUsers={setUsers} />
      {authCtx.isAdmin && (
        <div className="mt-4 mb-8">
          <DKGTable
            nodeProxyAddresses={nodeProxyAddresses}
            setNodeProxyAddresses={setNodeProxyAddresses}
          />
        </div>
      )}
    </div>
  ) : (
    <Loading />
  );
};
export default Admin;
