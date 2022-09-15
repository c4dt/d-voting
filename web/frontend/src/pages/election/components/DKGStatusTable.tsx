import { FC } from 'react';
import { useTranslation } from 'react-i18next';
import { ID } from 'types/configuration';
import { OngoingAction } from 'types/election';
import { InternalDKGInfo } from 'types/node';
import DKGStatusRow from './DKGStatusRow';

type DKGStatusTableProps = {
  roster: string[];
  electionId: ID;
  nodeProxyAddresses: Map<string, string>;
  setNodeProxyAddresses: (nodeProxy: Map<string, string>) => void;
  setTextModalError: (error: string) => void;
  setShowModalError: (show: boolean) => void;
  // notify to start initialization
  ongoingAction: OngoingAction;
  // notify the parent of the new state
  notifyDKGState: (node: string, info: InternalDKGInfo) => void;
  nodeToSetup: [string, string];
  notifyLoading: (node: string, loading: boolean) => void;
};

const DKGStatusTable: FC<DKGStatusTableProps> = ({
  roster,
  electionId,
  nodeProxyAddresses,
  setNodeProxyAddresses,
  setTextModalError,
  setShowModalError,
  ongoingAction,
  notifyDKGState,
  nodeToSetup,
  notifyLoading,
}) => {
  const { t } = useTranslation();

  return (
    <div>
      <div className="relative divide-y overflow-x-auto shadow-md sm:rounded-lg mt-2">
        <table className="w-full text-sm text-left text-gray-500">
          <thead className="text-xs text-gray-700 uppercase bg-gray-50">
            <tr>
              <th scope="col" className="px-6 py-3">
                {t('node')}
              </th>
              <th scope="col" className="px-6 py-3">
                {t('status')}
              </th>
            </tr>
          </thead>
          <tbody>
            {roster !== null &&
              roster.map((node, index) => (
                <DKGStatusRow
                  key={index}
                  electionId={electionId}
                  node={node}
                  index={index}
                  nodeProxyAddresses={nodeProxyAddresses}
                  setNodeProxyAddresses={setNodeProxyAddresses}
                  setTextModalError={setTextModalError}
                  setShowModalError={setShowModalError}
                  ongoingAction={ongoingAction}
                  notifyDKGState={notifyDKGState}
                  nodeToSetup={nodeToSetup}
                  notifyLoading={notifyLoading}
                />
              ))}
          </tbody>
        </table>
      </div>
    </div>
  );
};

export default DKGStatusTable;
